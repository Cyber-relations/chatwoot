# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Toybaco::Security::SlackSignatureRequired, type: :request do
  let(:secret) { 'synthetic-slack-secret' }
  let(:timestamp) { Time.current.to_i.to_s }
  let(:body) { { type: 'url_verification', challenge: 'fixture' }.to_json }
  let(:signature) { "v0=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "v0:#{timestamp}:#{body}")}" }
  let(:headers) do
    { 'CONTENT_TYPE' => 'application/json', 'X-Slack-Request-Timestamp' => timestamp, 'X-Slack-Signature' => signature }
  end

  before do
    allow(GlobalConfigService).to receive(:load).with('SLACK_SIGNING_SECRET', nil).and_return(secret)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('SLACK_SIGNING_SECRET', nil).and_return(nil)
    allow(Rails.logger).to receive(:warn)
    allow(Socket).to receive(:tcp).and_raise('unexpected TCP connection')
    allow(TCPSocket).to receive(:new).and_raise('unexpected TCP connection')
    allow(TCPSocket).to receive(:open).and_raise('unexpected TCP connection')
    allow(Resolv).to receive(:getaddresses).and_raise('unexpected DNS lookup')
  end

  shared_examples 'a rejected Slack callback' do
    it 'rejects before constructing the consumer or creating a message' do
      expect(Integrations::Slack::IncomingMessageBuilder).not_to receive(:new)
      expect { post '/api/v1/integrations/webhooks', params: body, headers: headers }.not_to change(Message, :count)

      expect(response).to have_http_status(:unauthorized)
      expect(Rails.logger).to have_received(:warn).with('Toybaco webhook rejected: invalid Slack signature').once
    end
  end

  [nil, '', ' '].each do |configuration|
    context "with blank configuration #{configuration.inspect}" do
      before { allow(GlobalConfigService).to receive(:load).with('SLACK_SIGNING_SECRET', nil).and_return(configuration) }

      it_behaves_like 'a rejected Slack callback'
    end
  end

  context 'without a signature' do
    let(:headers) { { 'CONTENT_TYPE' => 'application/json' } }

    it_behaves_like 'a rejected Slack callback'
  end

  context 'with an invalid signature' do
    let(:signature) { "v0=#{'0' * 64}" }

    it_behaves_like 'a rejected Slack callback'
  end

  context 'with a stale timestamp' do
    let(:timestamp) { 10.minutes.ago.to_i.to_s }

    it_behaves_like 'a rejected Slack callback'
  end

  context 'with a future timestamp' do
    let(:timestamp) { 10.minutes.from_now.to_i.to_s }

    it_behaves_like 'a rejected Slack callback'
  end

  context 'with a malformed but correctly signed timestamp' do
    let(:timestamp) { "#{Time.current.to_i}junk" }

    it_behaves_like 'a rejected Slack callback'
  end

  it 'processes a correctly signed challenge through the real builder' do
    post '/api/v1/integrations/webhooks', params: body, headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq('challenge' => 'fixture')
    expect(Rails.logger).not_to have_received(:warn)
  end

  it 'retains the ENV fallback for a blank installation configuration' do
    allow(GlobalConfigService).to receive(:load).with('SLACK_SIGNING_SECRET', nil).and_return('')
    allow(ENV).to receive(:fetch).with('SLACK_SIGNING_SECRET', nil).and_return(secret)
    post '/api/v1/integrations/webhooks', params: body, headers: headers

    expect(response.parsed_body).to eq('challenge' => 'fixture')
  end

  it 'ignores a query challenge while preserving the signed body bytes' do
    post '/api/v1/integrations/webhooks?challenge=query-challenge&type=event_callback', params: body, headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq('challenge' => 'fixture')
  end

  ['[]', 'null', '{'].each do |invalid_body|
    context "with signed invalid event JSON #{invalid_body.inspect}" do
      let(:body) { invalid_body }

      it 'rejects without using the query as an event' do
        expect(Integrations::Slack::IncomingMessageBuilder).not_to receive(:new)
        post '/api/v1/integrations/webhooks?type=url_verification&challenge=query', params: body, headers: headers

        expect(response).to have_http_status(:bad_request)
      end
    end
  end

  it 'dispatches correctly signed events through the real builder' do
    event = { type: 'event_callback', event: { type: 'link_shared', user: 'fixture', links: [] } }.to_json
    event_headers = headers.merge('X-Slack-Signature' => "v0=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "v0:#{timestamp}:#{event}")}")
    allow(SlackUnfurlJob).to receive(:perform_later)
    post '/api/v1/integrations/webhooks', params: event, headers: event_headers

    expect(response).to have_http_status(:ok)
    expect(SlackUnfurlJob).to have_received(:perform_later).once
  end

  context 'with an existing Slack integration and conversation' do
    let(:conversation) { create(:conversation, identifier: 'fixture-thread') }
    let(:hook) { create(:integrations_hook, account: conversation.account, reference_id: 'fixture-channel') }
    let(:slack_client) { instance_double(Slack::Web::Client) }
    let(:body) do
      { type: 'event_callback', event: { type: 'message', user: 'fixture-user', channel: hook.reference_id,
                                         thread_ts: conversation.identifier, ts: '1.000001', text: 'signed fixture',
                                         blocks: [{ type: 'rich_text' }] } }.to_json
    end

    before do
      allow(Slack::Web::Client).to receive(:new).and_return(slack_client)
      allow(slack_client).to receive(:users_info).and_return(user: { name: 'fixture', profile: { email: 'fixture@example.test' } })
      body
    end

    it 'persists a correctly signed message through the real consumer' do
      expect do
        post '/api/v1/integrations/webhooks', params: body, headers: headers
      end.to change(conversation.messages, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(conversation.messages.last).to have_attributes(content: 'signed fixture', message_type: 'outgoing')
    end

    it 'persists the signed message when a query supplies a replacement event' do
      query_event = JSON.parse(body).fetch('event').merge('text' => 'query replacement', 'ts' => '2.000002')
      query = { event: query_event }.to_query

      expect do
        post "/api/v1/integrations/webhooks?#{query}", params: body, headers: headers
      end.to change(conversation.messages, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(conversation.messages.last).to have_attributes(content: 'signed fixture', message_type: 'outgoing')
    end

    context 'without signing configuration' do
      before { allow(GlobalConfigService).to receive(:load).with('SLACK_SIGNING_SECRET', nil).and_return(nil) }

      it_behaves_like 'a rejected Slack callback'
    end
  end
end
