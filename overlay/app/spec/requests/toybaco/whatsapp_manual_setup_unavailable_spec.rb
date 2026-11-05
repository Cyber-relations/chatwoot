# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Toybaco unavailable WhatsApp manual setup', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:headers) { { 'api_access_token' => admin.access_token.token } }
  let(:channel) do
    with_modified_env('TOYBACO_WHATSAPP_ENABLED' => 'true') do
      create(:channel_whatsapp, provider: 'whatsapp_cloud', account: account,
                                validate_provider_config: false, sync_templates: false).tap do |whatsapp|
        whatsapp.update!(provider_config: whatsapp.provider_config.merge('source' => 'manual_setup_v2'))
      end
    end
  end
  let(:base) { "/api/v1/accounts/#{account.id}/whatsapp/manual/#{channel.inbox.id}" }

  before do
    channel
    headers
  end

  def expect_no_meta_access
    expect(Whatsapp::ManualWebhookStatusService).not_to receive(:new)
    expect(Whatsapp::WebhookSetupService).not_to receive(:new)
  end

  actions = { 'webhook_status' => :get, 'setup_webhook' => :post }.freeze

  [nil, 'false'].each do |disabled|
    context "when the WhatsApp switch is #{disabled.inspect}" do
      actions.each do |action, verb|
        it "rejects #{action} for an existing manual-setup inbox before contacting Meta" do
          expect_no_meta_access
          before_state = channel.reload.attributes

          with_modified_env('TOYBACO_WHATSAPP_ENABLED' => disabled) do
            public_send(verb, "#{base}/#{action}", headers: headers, as: :json)
          end

          expect(response).to have_http_status(:unprocessable_entity)
          expect(response.parsed_body).to eq('message' => Toybaco::ChannelAvailability.error)
          expect(channel.reload.attributes).to eq(before_state)
        end
      end
    end
  end

  it 'keeps the upstream webhook status only when WhatsApp is explicitly enabled' do
    status = instance_double(Whatsapp::ManualWebhookStatusService, perform: { 'registered' => true })
    allow(Whatsapp::ManualWebhookStatusService).to receive(:new).and_return(status)

    with_modified_env('TOYBACO_WHATSAPP_ENABLED' => 'true') do
      get "#{base}/webhook_status", headers: headers, as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(status).to have_received(:perform).once
  end
end
