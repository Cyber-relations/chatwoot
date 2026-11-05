# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Enterprise::Webhooks::FirecrawlController, type: :request do
  let(:secret) { 'synthetic-firecrawl-key-1234' }
  let!(:assistant) { create(:captain_assistant) }
  let(:payload) { { type: 'crawl.page', data: [{ markdown: 'replacement', metadata: { sourceURL: 'https://example.test/document' } }] } }
  let(:token) { OpenSSL::HMAC.hexdigest('SHA256', secret, "firecrawl:#{assistant.account_id}:#{assistant.id}") }

  before do
    InstallationConfig.find_or_initialize_by(name: 'CAPTAIN_FIRECRAWL_API_KEY').update!(value: secret, locked: false)
    allow(Captain::Tools::FirecrawlParserJob).to receive(:perform_later)
  end

  def deliver(token: nil, target: assistant)
    query = { assistant_id: target.id, token: token }.compact.to_query
    post "/enterprise/webhooks/firecrawl?#{query}", params: payload, as: :json
  end

  [nil, '', " \t\n"].each do |value|
    it "rejects a real blank configuration #{value.inspect} before lookup, HMAC or enqueueing" do
      InstallationConfig.find_by!(name: 'CAPTAIN_FIRECRAWL_API_KEY').update!(value: value)
      expect(Firecrawl::Configuration.api_key).to eq(value)
      expect(Captain::Assistant).not_to receive(:find)
      expect(OpenSSL::HMAC).not_to receive(:hexdigest)

      expect { deliver }.not_to change(Captain::Document, :count)

      expect(response).to have_http_status(:unauthorized)
      expect(Captain::Tools::FirecrawlParserJob).not_to have_received(:perform_later)
    end
  end

  it 'rejects an absent database row despite a populated environment key' do
    InstallationConfig.find_by!(name: 'CAPTAIN_FIRECRAWL_API_KEY').destroy!
    with_modified_env('CAPTAIN_FIRECRAWL_API_KEY' => secret) do
      expect(Firecrawl::Configuration.api_key).to be_nil
      deliver
    end

    expect(response).to have_http_status(:unauthorized)
    expect(Captain::Tools::FirecrawlParserJob).not_to have_received(:perform_later)
  end

  it 'preserves an existing document when a blank key and omitted token target it' do
    document = create(:captain_document, assistant: assistant, account: assistant.account,
                                         external_link: 'https://example.test/document', content: 'original')
    original = document.reload.attributes
    InstallationConfig.find_by!(name: 'CAPTAIN_FIRECRAWL_API_KEY').update!(value: nil)

    deliver

    expect(response).to have_http_status(:unauthorized)
    expect(Captain::Tools::FirecrawlParserJob).not_to have_received(:perform_later)
    expect(document.reload.attributes).to eq(original)
  end

  [nil, '', ' ', 'wrong', ['array']].each do |value|
    it "rejects a missing, malformed or incorrect token #{value.inspect}" do
      deliver(token: value)

      expect(response).to have_http_status(:unauthorized)
      expect(Captain::Tools::FirecrawlParserJob).not_to have_received(:perform_later)
    end
  end

  it 'rejects the old suffix-derived token' do
    legacy = Digest::SHA256.hexdigest("#{secret[-4..]}#{assistant.id}#{assistant.account_id}")
    deliver(token: legacy)

    expect(response).to have_http_status(:unauthorized)
    expect(Captain::Tools::FirecrawlParserJob).not_to have_received(:perform_later)
  end

  it 'rejects a token generated with a different key sharing the same suffix' do
    forged = OpenSSL::HMAC.hexdigest('SHA256', 'different-key-1234', "firecrawl:#{assistant.account_id}:#{assistant.id}")
    deliver(token: forged)

    expect(response).to have_http_status(:unauthorized)
    expect(Captain::Tools::FirecrawlParserJob).not_to have_received(:perform_later)
  end

  it 'binds the credential to the assistant and account' do
    other = create(:captain_assistant)
    deliver(token: token, target: other)

    expect(response).to have_http_status(:unauthorized)
    expect(Captain::Tools::FirecrawlParserJob).not_to have_received(:perform_later)
  end

  it 'accepts the token emitted by the real crawl job and compares it securely' do
    document = build(:captain_document, assistant: assistant, account: assistant.account)
    callback = Captain::Documents::CrawlJob.new.send(:firecrawl_webhook_url, document)
    emitted_token = Rack::Utils.parse_query(URI.parse(callback).query).fetch('token')
    expect(emitted_token).to eq(token)
    expect(ActiveSupport::SecurityUtils).to receive(:secure_compare).with(token, token).and_call_original

    post URI.parse(callback).request_uri, params: payload, as: :json

    expect(response).to have_http_status(:ok)
    expect(Captain::Tools::FirecrawlParserJob).to have_received(:perform_later)
      .with(assistant_id: assistant.id, payload: payload[:data].first.deep_stringify_keys).once
  end
end
