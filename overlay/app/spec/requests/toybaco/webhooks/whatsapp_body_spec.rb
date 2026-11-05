# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'WhatsApp signed webhook body', type: :request do
  let(:secret) { 'synthetic-whatsapp-secret' }
  let(:channel) do
    create(:channel_whatsapp, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false,
                              provider_config: { 'app_secret' => secret })
  end
  let(:message) { { from: 'body-sender', id: 'body-id', type: 'text', text: { body: 'signed message' } } }
  let(:payload) do
    { object: 'whatsapp_business_account', entry: [{ changes: [{ field: 'messages', value: {
      metadata: { phone_number_id: channel.provider_config['phone_number_id'], display_phone_number: channel.phone_number },
      messages: [message]
    } }] }] }
  end
  let(:body) { payload.to_json }
  let(:query) do
    { phone_number: 'query-number', entry: [{ changes: [{ field: 'tracking_events', value: {
      metadata: { phone_number_id: 'query-id', display_phone_number: 'query-number' },
      messages: [{ from: 'query-sender', text: { body: 'query replacement' } }]
    } }] }] }.to_query
  end
  let(:headers) do
    { 'CONTENT_TYPE' => 'application/json', 'X-Hub-Signature-256' => "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, body)}" }
  end
  let(:service) { instance_double(Whatsapp::IncomingMessageWhatsappCloudService, perform: nil) }

  around do |example|
    with_modified_env('TOYBACO_WHATSAPP_ENABLED' => 'true') { example.run }
  end

  before do
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('WHATSAPP_APP_SECRET', nil).and_return(nil)
    allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(service)
  end

  def deliver(query_string = '')
    perform_enqueued_jobs(only: Webhooks::WhatsappEventsJob) do
      post "/webhooks/whatsapp/#{channel.phone_number}#{query_string}", params: body, headers: headers
    end
  end

  def expect_body_delivery
    expect(response).to have_http_status(:ok)
    expect(Whatsapp::IncomingMessageWhatsappCloudService).to have_received(:new)
      .with(inbox: channel.inbox, params: JSON.parse(body), locked_sender_id: 'body-sender').once
    expect(service).to have_received(:perform).once
  end

  it 'delivers a legitimate signed event through the job' do
    deliver

    expect_body_delivery
  end

  it 'ignores a query replacement for channel selection, tracking detection and message delivery' do
    deliver("?#{query}")

    expect_body_delivery
  end

  context 'with a payload using the URL channel fallback' do
    let(:payload) { { phone_number: 'body-is-not-a-route', messages: [message] } }

    it 'keeps the route number separate from body and query data through job serialization' do
      deliver("?#{query}")

      expect_body_delivery
    end
  end

  it 'rejects a changed signature without dispatching' do
    expect(Webhooks::WhatsappEventsJob).not_to receive(:perform_later)
    invalid_headers = headers.merge('X-Hub-Signature-256' => "sha256=#{'0' * 64}")

    post "/webhooks/whatsapp/#{channel.phone_number}?#{query}", params: body, headers: invalid_headers

    expect(response).to have_http_status(:unauthorized)
    expect(Whatsapp::IncomingMessageWhatsappCloudService).not_to have_received(:new)
  end
end
