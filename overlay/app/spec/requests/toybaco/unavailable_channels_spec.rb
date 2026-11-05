# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Toybaco unavailable channels', type: :request do
  before do
    allow(ENV).to receive(:[]).and_call_original
    %w[TOYBACO_SMS_ENABLED TOYBACO_WHATSAPP_ENABLED].each do |key|
      allow(ENV).to receive(:[]).with(key).and_return(nil)
    end
    allow(Rails.logger).to receive(:warn)
    # A missing request stub must not open a provider connection.
    allow(Socket).to receive(:tcp).and_raise(RSpec::Expectations::ExpectationNotMetError, 'unexpected TCP connection')
    allow(TCPSocket).to receive(:open).and_raise(RSpec::Expectations::ExpectationNotMetError, 'unexpected TCP connection')
    allow(TCPSocket).to receive(:new).and_raise(RSpec::Expectations::ExpectationNotMetError, 'unexpected TCP connection')
  end

  it 'rejects unsigned SMS before selecting a channel or enqueueing' do
    expect(Channel::Sms).not_to receive(:find_by)
    expect(Webhooks::SmsEventsJob).not_to receive(:perform_later)
    post '/webhooks/sms/15555550101', params: [{ type: 'message-received', to: '15555550202',
                                                 message: { text: 'private fixture body' } }].to_json,
                                      headers: { 'CONTENT_TYPE' => 'application/json' }

    expect(response).to have_http_status(:not_found)
    expect(Rails.logger).to have_received(:warn).with('Toybaco webhook rejected: sms channel is not offered').once
  end

  signed_states = [false, true].freeze

  %w[default whatsapp_cloud].each do |provider|
    signed_states.each do |signed|
      it "rejects #{provider} callbacks (signed=#{signed}) before lookup or enqueueing" do
        # 360dialog sends messages/contacts and no Meta signature. Cloud uses entry/changes.
        body = if provider == 'default'
                 { contacts: [{ wa_id: '15555550101' }], messages: [{ from: '15555550101', type: 'text', text: { body: 'fixture' } }] }
               else
                 { object: 'whatsapp_business_account', entry: [{ changes: [{ field: 'messages', value: { messages: [] } }] }] }
               end
        expect(Channel::Whatsapp).not_to receive(:find_by)
        expect(Webhooks::WhatsappEventsJob).not_to receive(:perform_later)
        secret = 'synthetic-cloud-secret'
        allow(GlobalConfigService).to receive(:load).with('WHATSAPP_APP_SECRET', nil).and_return(secret)
        signature = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, body.to_json)}" if signed
        post '/webhooks/whatsapp/15555550101', params: body.to_json,
                                               headers: { 'CONTENT_TYPE' => 'application/json', 'X-Hub-Signature-256' => signature }

        expect(response).to have_http_status(:not_found)
        expect(Rails.logger).to have_received(:warn).with('Toybaco webhook rejected: whatsapp channel is not offered').once
      end
    end
  end

  it 'also rejects the WhatsApp verification handshake' do
    expect(Channel::Whatsapp).not_to receive(:find_by)
    get '/webhooks/whatsapp/15555550101', params: { 'hub.verify_token' => 'fixture', 'hub.challenge' => 'fixture' }

    expect(response).to have_http_status(:not_found)
  end

  it 'has no Platform API inbox creation route in the pinned application' do
    expect do
      Rails.application.routes.recognize_path('/platform/api/v1/accounts/1/inboxes', method: :post)
    end.to raise_error(ActionController::RoutingError)
  end

  twilio_paths = ['/twilio/callback', '/twilio/delivery_status'].freeze

  %w[sms whatsapp].each do |type|
    it "rejects Twilio #{type} messages and delivery callbacks before enqueueing" do
      number = type == 'whatsapp' ? 'whatsapp:+15555550101' : '+15555550101'
      expect(Webhooks::TwilioEventsJob).not_to receive(:perform_later)
      expect(Webhooks::TwilioDeliveryStatusJob).not_to receive(:perform_later)
      twilio_paths.each do |path|
        post path, params: { From: number, To: number, Body: 'fixture', MessageStatus: 'delivered' }
        expect(response).to have_http_status(:not_found)
      end
      expect(Rails.logger).to have_received(:warn).with("Toybaco webhook rejected: #{type} channel is not offered").twice
    end
  end

  context 'with an authenticated store administrator' do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account, role: :administrator) }
    let(:headers) { { 'api_access_token' => user.access_token.token } }
    let(:base) { "/api/v1/accounts/#{account.id}" }

    %w[sms whatsapp voice].each do |type|
      it "rejects #{type} inbox creation through the dashboard/account API" do
        account.enable_features!('channel_voice') if type == 'voice'
        models = [Channel::Sms, Channel::Whatsapp, Channel::TwilioSms]
        counts = models.map(&:count)
        expect do
          post "#{base}/inboxes", params: { name: 'fixture', channel: { type: type, phone_number: '+15555550101' } }, headers: headers
        end.not_to change(Inbox, :count)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq('error' => Toybaco::ChannelAvailability.error)
        expect(models.map(&:count)).to eq(counts)
      end
    end

    %w[sms whatsapp].each do |type|
      it "rejects Twilio #{type} creation before provider authentication" do
        expect(Twilio::REST::Client).not_to receive(:new)
        expect do
          post "#{base}/channels/twilio_channel", params: { twilio_channel: { medium: type, name: 'fixture' } }, headers: headers
        end.not_to change(Channel::TwilioSms, :count)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq('error' => Toybaco::ChannelAvailability.error)
      end
    end

    it 'rejects embedded signup before exchanging provider credentials' do
      expect(Whatsapp::EmbeddedSignupService).not_to receive(:new)
      post "#{base}/whatsapp/authorization", params: { code: 'fixture', waba_id: 'fixture' }, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq('success' => false, 'error' => Toybaco::ChannelAvailability.error)
    end

    %w[preview connect].each do |action|
      it "rejects manual WhatsApp #{action} before contacting Meta" do
        expect(Whatsapp::ManualSetupService).not_to receive(:new)
        expect(Whatsapp::ManualSetupValidationService).not_to receive(:new)
        post "#{base}/whatsapp/manual/#{action}", params: { access_token: 'fixture' }, headers: headers

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq('message' => Toybaco::ChannelAvailability.error)
      end
    end

    it 'continues to create an offered API inbox' do
      expect do
        post "#{base}/inboxes", params: { name: 'fixture', channel: { type: 'api' } }, headers: headers
      end.to change(Inbox, :count).by(1)
      expect(response).to have_http_status(:ok)
    end
  end

  [Channel::Sms, Channel::Whatsapp, Channel::TwilioSms].each do |model|
    it "blocks #{model} through model/service creation, even with validation disabled" do
      channel = model.new
      expect(channel.save).to be(false)
      expect(channel.errors[:base]).to include(Toybaco::ChannelAvailability.error)
      expect(channel.save(validate: false)).to be(false)
      expect(channel).not_to be_persisted
    end
  end

  it 'also blocks Twilio WhatsApp model creation' do
    channel = Channel::TwilioSms.new(medium: :whatsapp)
    expect(channel.save).to be(false)
    expect(channel.errors[:base]).to include(Toybaco::ChannelAvailability.error)
    expect(channel.save(validate: false)).to be(false)
    expect(channel).not_to be_persisted
  end
end
