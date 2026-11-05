# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhooks::LineEventsJob do
  let(:body) { { events: [] }.to_json }
  let(:secret) { 'synthetic-line-secret' }
  let(:signature) { Base64.strict_encode64(OpenSSL::HMAC.digest('SHA256', secret, body)) }
  let(:inbox) { instance_double(Inbox, id: 1) }
  let(:channel) { instance_double(Channel::Line, line_channel_secret: secret, line_channel_id: 'fixture', account_id: 1, inbox: inbox) }
  let(:service) { instance_double(Line::IncomingMessageService, perform: nil) }

  before do
    allow(Channel::Line).to receive(:find_by).with(line_channel_id: 'fixture').and_return(channel)
    allow(Line::IncomingMessageService).to receive(:new).and_return(service)
  end

  def perform(signature_value, post_body = body)
    described_class.new.perform(params: { :line_channel_id => 'fixture', 'line' => { 'events' => [] } },
                                signature: signature_value, post_body: post_body)
  end

  it 'compares the HMAC using secure_compare and processes a valid event' do
    expect(ActiveSupport::SecurityUtils).to receive(:secure_compare).with(signature, signature).and_call_original

    perform(signature)

    expect(service).to have_received(:perform)
  end

  [nil, '', 'incorrect', 'x' * 44].each do |invalid|
    it "rejects an invalid signature #{invalid.inspect}" do
      perform(invalid)

      expect(Line::IncomingMessageService).not_to have_received(:new)
    end
  end

  it 'rejects a signature from another channel' do
    perform(Base64.strict_encode64(OpenSSL::HMAC.digest('SHA256', 'another-channel-secret', body)))

    expect(Line::IncomingMessageService).not_to have_received(:new)
  end

  it 'rejects a modified body' do
    perform(signature, "#{body} ")

    expect(Line::IncomingMessageService).not_to have_received(:new)
  end

  it 'ignores conflicting events in a previously queued job' do
    described_class.new.perform(params: { :line_channel_id => 'fixture', 'line' => { 'events' => [{ 'message' => { 'text' => 'replacement' } }] } },
                                signature: signature, post_body: body)

    expect(Line::IncomingMessageService).to have_received(:new).with(inbox: inbox, params: JSON.parse(body)).once
  end
end
