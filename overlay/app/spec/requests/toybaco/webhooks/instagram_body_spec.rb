# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Instagram signed webhook body', type: :request do
  let(:secret) { 'synthetic-instagram-secret' }
  let(:message) { { sender: { id: 'body-sender' }, recipient: { id: 'body-recipient' }, message: { text: 'signed message' } } }
  let(:body) { { object: 'instagram', entry: [{ id: 'body-page', messaging: [message] }] }.to_json }
  let(:query) do
    { object: 'instagram', entry: [{ id: 'query-page', messaging: [{ message: { text: 'query replacement', is_echo: true } }] }] }.to_query
  end
  let(:headers) do
    { 'CONTENT_TYPE' => 'application/json', 'X-Hub-Signature-256' => "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, body)}" }
  end

  before do
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('INSTAGRAM_APP_SECRET', nil).and_return(secret)
    allow(GlobalConfigService).to receive(:load).with('FB_APP_SECRET', nil).and_return(nil)
    allow(Webhooks::InstagramEventsJob).to receive(:perform_later)
  end

  [false, true].each do |query_present|
    it "enqueues only the signed entry with query #{query_present ? 'present' : 'absent'}" do
      expect(Webhooks::InstagramEventsJob).not_to receive(:set)
      post "/webhooks/instagram#{query_present ? "?#{query}" : ''}", params: body, headers: headers

      expect(response).to have_http_status(:ok)
      expect(Webhooks::InstagramEventsJob).to have_received(:perform_later).with(JSON.parse(body).fetch('entry')).once
    end
  end

  it 'looks up signing channels using only body recipients' do
    expect(Channel::Instagram).to receive(:find_by).with(instagram_id: 'body-recipient').and_return(nil)
    expect(Channel::FacebookPage).to receive(:find_by).with(instagram_id: 'body-recipient').and_return(nil)

    post "/webhooks/instagram?#{query}", params: body, headers: headers

    expect(response).to have_http_status(:ok)
    expect(Webhooks::InstagramEventsJob).to have_received(:perform_later).with(JSON.parse(body).fetch('entry')).once
  end

  it 'still rejects an invalid signature before enqueueing' do
    post "/webhooks/instagram?#{query}", params: body, headers: headers.merge('X-Hub-Signature-256' => "sha256=#{'0' * 64}")

    expect(response).to have_http_status(:unauthorized)
    expect(Webhooks::InstagramEventsJob).not_to have_received(:perform_later)
  end

  context 'with a signed echo event' do
    let(:message) { super().merge(message: { text: 'signed echo', is_echo: true }) }

    it 'retains the echo delay when the query supplies a different event' do
      delayed_job = instance_double(ActiveJob::ConfiguredJob, perform_later: nil)
      expect(Webhooks::InstagramEventsJob).to receive(:set).with(wait: 2.seconds).and_return(delayed_job)
      query_event = { object: 'instagram', entry: [{ messaging: [{ message: { text: 'query replacement' } }] }] }.to_query

      post "/webhooks/instagram?#{query_event}", params: body, headers: headers

      expect(response).to have_http_status(:ok)
      expect(delayed_job).to have_received(:perform_later).with(JSON.parse(body).fetch('entry')).once
      expect(Webhooks::InstagramEventsJob).not_to have_received(:perform_later)
    end
  end
end
