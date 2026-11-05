# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Toybaco inbox provider APIs for unavailable channels', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:voice_channel) do
    with_modified_env('TOYBACO_SMS_ENABLED' => 'true') do
      create(:channel_twilio_sms, :with_voice, account: account, provider_config: { 'inbound_calls_enabled' => true })
    end
  end
  let(:whatsapp_channel) do
    with_modified_env('TOYBACO_WHATSAPP_ENABLED' => 'true') do
      create(:channel_whatsapp, provider: 'whatsapp_cloud', account: account,
                                validate_provider_config: false, sync_templates: false)
    end
  end
  let(:channels) { { voice: voice_channel, whatsapp: whatsapp_channel } }
  let(:switches) { { voice: 'TOYBACO_SMS_ENABLED', whatsapp: 'TOYBACO_WHATSAPP_ENABLED' } }
  let(:rejections) do
    { voice: 'Toybaco API rejected: sms channel is not offered', whatsapp: 'Toybaco API rejected: whatsapp channel is not offered' }
  end

  before do
    allow(Rails.logger).to receive(:warn)
    channels.each_value(&:inbox)
    admin
  end

  def inbox_request(channel, action)
    base = "/api/v1/accounts/#{account.id}/inboxes/#{channel.inbox.id}"
    case action
    when :update then [:patch, base, { name: 'changed-name' }]
    when :health then [:get, "#{base}/health", {}]
    when :whatsapp_business_management_token then [:put, "#{base}/#{action}", { business_management_token: 'synthetic' }]
    else [:post, "#{base}/#{action}", { inbound_calls_enabled: false, call_recording_enabled: false }]
    end
  end

  def expect_no_provider_access
    expect(Twilio::REST::Client).not_to receive(:new)
    expect(Twilio::WebhookSetupService).not_to receive(:new)
    expect(Twilio::HealthService).not_to receive(:new)
    expect(Whatsapp::WebhookSetupService).not_to receive(:new)
    expect(Whatsapp::HealthService).not_to receive(:new)
    expect(Whatsapp::BusinessManagementTokenService).not_to receive(:new)
    [Channels::Whatsapp::TemplatesSyncJob, Channels::Twilio::TemplatesSyncJob, Channels::Twilio::WebhookSetupJob].each do |job|
      expect(job).not_to receive(:perform_later)
    end
  end

  def snapshot(channel)
    [channel.reload.attributes, channel.inbox.reload.attributes]
  end

  actions = {
    voice: %i[update register_webhook health set_inbound_calls set_call_recording],
    whatsapp: %i[update register_webhook health sync_templates whatsapp_business_management_token
                 enable_whatsapp_calling disable_whatsapp_calling set_inbound_calls set_call_recording]
  }.freeze
  disabled_values = [nil, 'false'].freeze

  actions.each do |kind, kind_actions|
    disabled_values.each do |disabled|
      context "with an existing #{kind} inbox while its switch is #{disabled.inspect}" do
        kind_actions.each do |action|
          it "rejects #{action} before provider access or record changes" do
            channel = channels.fetch(kind)
            expect_no_provider_access
            before_state = snapshot(channel)
            verb, path, params = inbox_request(channel, action)

            with_modified_env(switches.fetch(kind) => disabled) do
              public_send(verb, path, params: params, headers: admin.create_new_auth_token, as: :json)
            end

            expect(response).to have_http_status(:unprocessable_entity)
            expect(response.parsed_body['error']).to eq(Toybaco::ChannelAvailability.error)
            expect(snapshot(channel)).to eq(before_state)
            expect(Rails.logger).to have_received(:warn).with(rejections.fetch(kind)).once
          end
        end
      end
    end
  end

  it 'keeps the upstream health API when SMS is explicitly enabled' do
    health = instance_double(Twilio::HealthService, perform: { status: 'synthetic' })
    allow(Twilio::HealthService).to receive(:new).and_return(health)

    with_modified_env('TOYBACO_SMS_ENABLED' => 'true') do
      get "/api/v1/accounts/#{account.id}/inboxes/#{voice_channel.inbox.id}/health", headers: admin.create_new_auth_token, as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(health).to have_received(:perform).once
    expect(Rails.logger).not_to have_received(:warn).with(rejections.fetch(:voice))
  end
end
