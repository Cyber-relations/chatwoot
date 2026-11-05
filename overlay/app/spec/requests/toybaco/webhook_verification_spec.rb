# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Toybaco webhook verification', type: :request do
  let(:secret) { 'synthetic-signing-secret' }

  before do
    allow(GlobalConfigService).to receive(:load).and_call_original
  end

  describe 'TikTok signature parsing' do
    let(:body) { { event: 'im_receive_msg' }.to_json }

    before do
      allow(GlobalConfigService).to receive(:load).with('TIKTOK_APP_SECRET', nil).and_return(secret)
      allow(Webhooks::TiktokEventsJob).to receive(:perform_later)
    end

    ['broken', 't=123,s=abc,broken', 't=123,s=abc=def', 't=123,s='].each do |header|
      it "rejects malformed signature #{header.inspect} without enqueueing" do
        post '/webhooks/tiktok', params: body,
                                 headers: { 'CONTENT_TYPE' => 'application/json', 'Tiktok-Signature' => header }

        expect(response).to have_http_status(:unauthorized)
        expect(Webhooks::TiktokEventsJob).not_to have_received(:perform_later)
      end
    end

    it 'still accepts a correctly signed request' do
      timestamp = Time.current.to_i
      signature = OpenSSL::HMAC.hexdigest('SHA256', secret, "#{timestamp}.#{body}")
      post '/webhooks/tiktok', params: body,
                               headers: { 'CONTENT_TYPE' => 'application/json', 'Tiktok-Signature' => "t=#{timestamp},s=#{signature}" }

      expect(response).to have_http_status(:ok)
      expect(Webhooks::TiktokEventsJob).to have_received(:perform_later).with(JSON.parse(body))
    end
  end

  describe 'WhatsApp verify token when explicitly enabled' do
    let(:channel) { instance_double(Channel::Whatsapp, provider_config: { 'webhook_verify_token' => secret }) }

    before do
      allow(Toybaco::ChannelAvailability).to receive(:enabled?).with('whatsapp').and_return(true)
      allow(Channel::Whatsapp).to receive(:find_by).with(phone_number: '12345').and_return(channel)
    end

    it 'uses secure_compare for the configured token' do
      expect(ActiveSupport::SecurityUtils).to receive(:secure_compare).with(secret, secret).and_call_original

      get '/webhooks/whatsapp/12345', params: { 'hub.verify_token' => secret, 'hub.challenge' => 'challenge' }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('challenge')
    end

    [nil, '', 'wrong'].each do |token|
      it "rejects an absent or incorrect token #{token.inspect}" do
        get '/webhooks/whatsapp/12345', params: { 'hub.verify_token' => token }

        expect(response).to have_http_status(:unauthorized)
      end
    end

    it 'rejects a blank configured token' do
      allow(channel).to receive(:provider_config).and_return('webhook_verify_token' => '')
      get '/webhooks/whatsapp/12345', params: { 'hub.verify_token' => '' }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'Instagram verify tokens' do
    before do
      allow(GlobalConfigService).to receive(:load).with('IG_VERIFY_TOKEN', '').and_return('')
      allow(GlobalConfigService).to receive(:load).with('INSTAGRAM_VERIFY_TOKEN', '').and_return('')
    end

    it 'rejects an empty supplied token when neither secret is configured' do
      get '/webhooks/instagram', params: { 'hub.verify_token' => '', 'hub.challenge' => 'challenge' }

      expect(response).to have_http_status(:unauthorized)
    end

    %w[IG_VERIFY_TOKEN INSTAGRAM_VERIFY_TOKEN].each do |name|
      it "securely compares #{name}" do
        allow(GlobalConfigService).to receive(:load).with(name, '').and_return(secret)
        expect(ActiveSupport::SecurityUtils).to receive(:secure_compare).with(secret, secret).and_call_original

        get '/webhooks/instagram', params: { 'hub.verify_token' => secret, 'hub.challenge' => 'challenge' }

        expect(response).to have_http_status(:ok)
      end
    end
  end
end
