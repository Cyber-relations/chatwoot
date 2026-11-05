# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Facebook webhook guards', type: :request do
  let(:server) { Rack::MockRequest.new(Facebook::Messenger::Server) }
  let(:provider) { ChatwootFbProvider.new }
  let(:body) { { entry: [{ id: '42', messaging: [{ message: { text: 'synthetic message' } }] }] }.to_json }

  before do
    allow(Facebook::Messenger.config).to receive(:provider).and_return(provider)
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('FB_VERIFY_TOKEN', '').and_return('synthetic-verify-token')
    allow(GlobalConfigService).to receive(:load).with('FB_APP_SECRET', '').and_return(nil)
    allow(Channel::FacebookPage).to receive(:where).with(page_id: '42').and_return([])
    allow(Facebook::Messenger::Bot).to receive(:receive)
  end

  it 'rejects the wrong handshake token with 403 and no challenge' do
    result = server.get('/?hub.verify_token=wrong&hub.challenge=challenge')

    expect(result.status).to eq(403)
    expect(result.body).not_to include('challenge')
  end

  it 'securely accepts the configured handshake token' do
    expect(ActiveSupport::SecurityUtils).to receive(:secure_compare)
      .with('synthetic-verify-token', 'synthetic-verify-token').and_call_original
    result = server.get('/?hub.verify_token=synthetic-verify-token&hub.challenge=challenge')

    expect(result.status).to eq(200)
    expect(result.body).to eq('challenge')
  end

  it 'rejects an empty handshake token and empty configuration' do
    allow(GlobalConfigService).to receive(:load).with('FB_VERIFY_TOKEN', '').and_return('')
    expect(server.get('/?hub.verify_token=&hub.challenge=challenge').status).to eq(403)
  end

  [nil, ''].each do |missing|
    it "rejects unsigned events with a #{missing.inspect} app secret" do
      allow(GlobalConfigService).to receive(:load).with('FB_APP_SECRET', '').and_return(missing)
      result = server.post('/', input: body)

      expect(result.status).to eq(400)
      expect(Facebook::Messenger::Bot).not_to have_received(:receive)
    end

    it "rejects an empty-key signature with a #{missing.inspect} app secret" do
      allow(GlobalConfigService).to receive(:load).with('FB_APP_SECRET', '').and_return(missing)
      result = server.post('/', :input => body, 'HTTP_X_HUB_SIGNATURE' => "sha1=#{OpenSSL::HMAC.hexdigest('sha1', '', body)}")

      expect(result.status).to eq(400)
      expect(Facebook::Messenger::Bot).not_to have_received(:receive)
    end
  end

  it 'still dispatches correctly signed events' do
    allow(GlobalConfigService).to receive(:load).with('FB_APP_SECRET', '').and_return('synthetic-app-secret')
    signature = "sha1=#{OpenSSL::HMAC.hexdigest('sha1', 'synthetic-app-secret', body)}"
    result = server.post('/', :input => body, 'HTTP_X_HUB_SIGNATURE' => signature)

    expect(result.status).to eq(200)
    expect(Facebook::Messenger::Bot).to have_received(:receive).with(JSON.parse(body).dig('entry', 0, 'messaging', 0))
  end

  it 'preserves the page-specific app secret when the global secret is absent' do
    allow(provider).to receive(:channel_app_secret_for).with('42').and_return('synthetic-page-secret')
    signature = "sha1=#{OpenSSL::HMAC.hexdigest('sha1', 'synthetic-page-secret', body)}"
    result = server.post('/', :input => body, 'HTTP_X_HUB_SIGNATURE' => signature)

    expect(result.status).to eq(200)
    expect(Facebook::Messenger::Bot).to have_received(:receive)
  end

  it 'dispatches only the signed body when query parameters replace the entry' do
    allow(GlobalConfigService).to receive(:load).with('FB_APP_SECRET', '').and_return('synthetic-app-secret')
    signature = "sha1=#{OpenSSL::HMAC.hexdigest('sha1', 'synthetic-app-secret', body)}"
    query = { entry: [{ id: 'query-page', messaging: [{ message: { text: 'query replacement' } }] }] }.to_query

    result = server.post("/?#{query}", :input => body, 'HTTP_X_HUB_SIGNATURE' => signature)

    expect(result.status).to eq(200)
    expect(Facebook::Messenger::Bot).to have_received(:receive).with(JSON.parse(body).dig('entry', 0, 'messaging', 0)).once
  end
end
