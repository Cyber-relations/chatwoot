# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Accounts::InboxesController, type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:headers) { { 'api_access_token' => user.access_token.token } }
  let(:twilio) do
    with_modified_env('TOYBACO_SMS_ENABLED' => 'true') { create(:channel_twilio_sms, :with_phone_number, account: account) }
  end
  let(:whatsapp) do
    with_modified_env('TOYBACO_WHATSAPP_ENABLED' => 'true') do
      create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false)
    end
  end

  around do |example|
    with_modified_env('TOYBACO_SMS_ENABLED' => nil, 'TOYBACO_WHATSAPP_ENABLED' => nil) { example.run }
  end

  before do
    account.enable_features!('channel_voice')
  end

  it 'refuses enabling voice on an existing SMS inbox and rolls back its other edits' do
    expect_no_provider_calls

    inbox = twilio.inbox
    previous_name = inbox.name
    patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
          params: { name: 'blocked edit', channel: { voice_enabled: true } }, headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['error']).to eq(Toybaco::ChannelAvailability.error)
    expect(twilio.reload.voice_enabled?).to be(false)
    expect(inbox.reload.name).to eq(previous_name)
  end

  it 'refuses WhatsApp voice activation before provider access' do
    expect_no_provider_calls

    post "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp.inbox.id}/enable_whatsapp_calling", headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['error']).to include(Toybaco::ChannelAvailability.error)
    expect(whatsapp.reload.voice_enabled?).to be(false)
  end

  it 'refuses enabling WhatsApp calling through the inbox settings API' do
    expect_no_provider_calls

    patch "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp.inbox.id}",
          params: { channel: { provider_config: { calling_enabled: true } } }, headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['error']).to eq(Toybaco::ChannelAvailability.error)
    expect(whatsapp.reload.voice_enabled?).to be(false)
  end

  def expect_no_provider_calls
    expect(Twilio::REST::Client).not_to receive(:new)
    expect(Twilio::VoiceWebhookSetupService).not_to receive(:new)
    expect(Whatsapp::Providers::WhatsappCloudService).not_to receive(:new)
    expect(Whatsapp::WebhookSetupService).not_to receive(:new)
  end
end
