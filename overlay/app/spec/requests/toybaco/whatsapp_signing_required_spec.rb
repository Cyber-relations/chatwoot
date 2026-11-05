# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'WhatsApp signatures when explicitly enabled', type: :request do
  let(:body) { { content: 'synthetic event' }.to_json }
  let(:config) { {} }
  let(:channel) { instance_double(Channel::Whatsapp, provider: provider, provider_config: config) }

  before do
    allow(Toybaco::ChannelAvailability).to receive(:enabled?).with('whatsapp').and_return(true)
    allow(Channel::Whatsapp).to receive(:find_by).with(phone_number: '12345').and_return(channel)
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('WHATSAPP_APP_SECRET', nil).and_return(nil)
    allow(GlobalConfig).to receive(:get_value).with('INACTIVE_WHATSAPP_NUMBERS').and_return('')
    allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)
  end

  def deliver(signature = nil)
    headers = { 'CONTENT_TYPE' => 'application/json' }
    headers['X-Hub-Signature-256'] = signature if signature
    post '/webhooks/whatsapp/12345', params: body, headers: headers
  end

  context 'with whatsapp_cloud' do
    let(:provider) { 'whatsapp_cloud' }

    it 'rejects an unsigned webhook when no secret is configured' do
      deliver

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
    end

    it 'rejects an empty-key signature when no secret is configured' do
      deliver("sha256=#{OpenSSL::HMAC.hexdigest('SHA256', '', body)}")

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
    end

    it 'preserves requests signed with a configured channel secret' do
      config['app_secret'] = 'synthetic-channel-secret'
      deliver("sha256=#{OpenSSL::HMAC.hexdigest('SHA256', config['app_secret'], body)}")

      expect(response).to have_http_status(:ok)
      expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later)
    end

    it 'rejects a mismatched signature even when a secret is configured' do
      config['app_secret'] = 'synthetic-channel-secret'
      deliver("sha256=#{'0' * 64}")

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
    end

    it 'preserves requests signed with the global app secret' do
      allow(GlobalConfigService).to receive(:load).with('WHATSAPP_APP_SECRET', nil).and_return('synthetic-global-secret')
      deliver("sha256=#{OpenSSL::HMAC.hexdigest('SHA256', 'synthetic-global-secret', body)}")

      expect(response).to have_http_status(:ok)
      expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later)
    end
  end

  context 'with 360dialog' do
    let(:provider) { 'default' }
    # On-premises 360dialog payload; no fabricated Meta signature.
    let(:body) do
      { contacts: [{ wa_id: '15555550101', profile: { name: 'Fixture' } }],
        messages: [{ from: '15555550101', id: 'fixture-message', timestamp: '1700000000',
                     type: 'text', text: { body: 'synthetic event' } }] }.to_json
    end

    it 'rejects a realistic 360dialog callback without applying Meta HMAC semantics' do
      expect(OpenSSL::HMAC).not_to receive(:hexdigest)
      post '/webhooks/whatsapp/12345', params: body,
                                       headers: { 'CONTENT_TYPE' => 'application/json', 'Authorization' => 'Bearer fixture' }

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
    end

    [nil, '', 'Bearer another-channel-token'].each do |authorization|
      it "rejects a missing or incorrect authentication header #{authorization.inspect}" do
        config['webhook_authorization'] = 'Bearer synthetic-dialog-token'
        allow(Rails.logger).to receive(:warn)
        post '/webhooks/whatsapp/12345', params: body,
                                         headers: { 'CONTENT_TYPE' => 'application/json', 'Authorization' => authorization }

        expect(response).to have_http_status(:unauthorized)
        expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
        expect(Rails.logger).to have_received(:warn)
          .with('WhatsApp webhook rejected: 360dialog signing contract is not configured')
      end
    end

    it 'fails closed without a verified provider authentication contract' do
      deliver

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
    end

    it 'still rejects an empty-key signature without a configured secret' do
      deliver("sha256=#{OpenSSL::HMAC.hexdigest('SHA256', '', body)}")

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
    end

    it 'still rejects a mismatched signature with a configured secret' do
      config['app_secret'] = 'synthetic-channel-secret'
      deliver("sha256=#{'0' * 64}")

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
    end

    it 'does not accept a Meta signature as 360dialog authentication' do
      config['app_secret'] = 'synthetic-channel-secret'
      deliver("sha256=#{OpenSSL::HMAC.hexdigest('SHA256', config['app_secret'], body)}")

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
    end
  end
end
