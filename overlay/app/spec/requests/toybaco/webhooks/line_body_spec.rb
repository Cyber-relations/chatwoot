# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'LINE signed webhook body', type: :request do
  let(:secret) { 'synthetic-line-secret' }
  let(:inbox) { instance_double(Inbox, id: 1) }
  let(:channel) { instance_double(Channel::Line, line_channel_secret: secret, line_channel_id: 'fixture', account_id: 1, inbox: inbox) }
  let(:service) { instance_double(Line::IncomingMessageService, perform: nil) }
  let(:body) do
    { events: [{ type: 'message', source: { userId: 'body-user' }, message: { id: 'body-id', type: 'text', text: 'signed message' } }] }.to_json
  end
  let(:headers) do
    { 'CONTENT_TYPE' => 'application/json', 'X-Line-Signature' => Base64.strict_encode64(OpenSSL::HMAC.digest('SHA256', secret, body)) }
  end

  before do
    allow(Channel::Line).to receive(:find_by).with(line_channel_id: 'fixture').and_return(channel)
    allow(Line::IncomingMessageService).to receive(:new).and_return(service)
  end

  ['', "?#{{ line_channel_id: 'query-channel', line: { events: [{ message: { text: 'query replacement' } }] } }.to_query}"].each do |query|
    it "passes only signed events to the service with query #{query.empty? ? 'absent' : 'present'}" do
      perform_enqueued_jobs(only: Webhooks::LineEventsJob) do
        post "/webhooks/line/fixture#{query}", params: body, headers: headers
      end

      expect(response).to have_http_status(:ok)
      expect(Line::IncomingMessageService).to have_received(:new).with(inbox: inbox, params: JSON.parse(body)).once
      expect(service).to have_received(:perform).once
    end
  end

  it 'does not process a body whose signature was changed' do
    perform_enqueued_jobs(only: Webhooks::LineEventsJob) do
      post '/webhooks/line/fixture', params: body, headers: headers.merge('X-Line-Signature' => 'invalid')
    end

    expect(Line::IncomingMessageService).not_to have_received(:new)
  end
end
