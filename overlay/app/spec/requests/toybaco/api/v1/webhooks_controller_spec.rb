# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::WebhooksController, :provider_stop, type: :request do
  disabled_switches = [nil, 'false'].freeze
  verbs = %i[get post].freeze
  let(:channel) { available_provider(:twitter) }
  let(:payload) { build(:twitter_message_create_event).with_indifferent_access }

  before do
    channel
    allow(Rails.logger).to receive(:warn)
    allow(Twitty::Facade).to receive(:new).and_call_original
    allow(Webhooks::Twitter).to receive(:new).and_call_original
  end

  def webhook_counts
    [Contact.count, ContactInbox.count, Conversation.count, Message.count]
  end

  def request_twitter(verb)
    params = verb == :get ? { crc_token: 'fixture' } : payload
    public_send(verb, '/webhooks/twitter', params: params, as: :json)
  end

  shared_examples 'a closed X webhook' do |verb, disabled|
    it "rejects #{verb.upcase} before upstream processing with X #{disabled.inspect}" do
      before_counts = webhook_counts
      with_modified_env('TOYBACO_TWITTER_ENABLED' => disabled) do
        expect { request_twitter(verb) }.not_to have_enqueued_job
      end

      expect(response).to have_http_status(:not_found)
      expect(webhook_counts).to eq(before_counts)
      expect(Twitty::Facade).not_to have_received(:new)
      expect(Webhooks::Twitter).not_to have_received(:new)
      expect(Rails.logger).to have_received(:warn).with('Toybaco webhook rejected: twitter channel is not offered').once
      expect_no_provider_requests
    end
  end

  verbs.each do |verb|
    disabled_switches.each { |disabled| it_behaves_like 'a closed X webhook', verb, disabled }
  end

  it 'computes the upstream CRC when X is explicitly enabled' do
    with_modified_env('TOYBACO_TWITTER_ENABLED' => 'true', 'TWITTER_CONSUMER_SECRET' => 'fixture-secret') { request_twitter(:get) }
    digest = OpenSSL::HMAC.digest('sha256', 'fixture-secret', 'fixture')

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq('response_token' => "sha256=#{Base64.strict_encode64(digest)}")
    expect(Twitty::Facade).to have_received(:new).once
    expect(Rails.logger).not_to have_received(:warn)
    expect_no_provider_requests
  end

  it 'processes the upstream event and queues its avatar when X is explicitly enabled' do
    with_modified_env('TOYBACO_TWITTER_ENABLED' => 'true', 'TWITTER_APP_ID' => 'fixture-parent') do
      expect { request_twitter(:post) }.to have_enqueued_job(Avatar::AvatarFromUrlJob)
    end

    expect(response).to have_http_status(:ok)
    expect(channel.inbox.contacts.count).to eq(1)
    expect(channel.inbox.messages.find_by(source_id: '123')).to have_attributes(content: 'Blue Bird', message_type: 'incoming')
    expect(Webhooks::Twitter).to have_received(:new).once
    expect(Rails.logger).not_to have_received(:warn)
    expect_no_provider_requests
  end
end
