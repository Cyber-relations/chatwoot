# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhooks::WhatsappController, type: :request do
  let!(:channel) do
    with_modified_env('TOYBACO_WHATSAPP_ENABLED' => 'true') do
      record = create(:channel_whatsapp, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false,
                                         provider_config: { 'calling_enabled' => true, 'inbound_calls_enabled' => true })
      record.account.enable_features!('channel_voice')
      record
    end
  end

  around do |example|
    with_modified_env('TOYBACO_WHATSAPP_ENABLED' => nil, 'TOYBACO_SMS_ENABLED' => 'true') { example.run }
  end

  before do
    allow(Rails.logger).to receive(:warn)
  end

  {
    calls: { calls: [{ id: 'wa_fixture', from: '15555550101', event: 'connect', session: { sdp: 'private fixture' } }] },
    statuses: { statuses: [{ id: 'wa_fixture', type: 'call', status: 'ACCEPTED' }] },
    messages: { messages: [{ from: '15555550101', type: 'interactive', interactive: { type: 'call_permission_reply' } }] }
  }.each do |kind, value|
    it "rejects unsigned Enterprise #{kind} events for an existing voice-enabled inbox" do
      expect_no_webhook_processing

      expect(channel.voice_enabled?).to be(true)
      payload = { object: 'whatsapp_business_account', entry: [{ changes: [{ field: kind == :messages ? 'messages' : 'calls', value: value }] }] }
      records = [Call, Conversation, Message, Contact, ContactInbox]

      expect do
        post "/webhooks/whatsapp/#{channel.phone_number}", params: payload, as: :json
      end.not_to(change { records.map(&:count) })

      expect(response).to have_http_status(:not_found)
      expect(Rails.logger).to have_received(:warn).with('Toybaco webhook rejected: whatsapp channel is not offered').once
    end
  end

  def expect_no_webhook_processing
    expect(Channel::Whatsapp).not_to receive(:find_by)
    expect(Whatsapp::WebhookChannelFinderService).not_to receive(:new)
    expect(Webhooks::WhatsappEventsJob).not_to receive(:perform_later)
    expect(Whatsapp::Providers::WhatsappCloudService).not_to receive(:new)
    expect(ActiveJob::Base.queue_adapter).not_to receive(:enqueue)
    expect(ActiveJob::Base.queue_adapter).not_to receive(:enqueue_at)
  end
end
