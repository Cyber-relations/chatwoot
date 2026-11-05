# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Toybaco::ChannelAvailability::ProviderGuard, :provider_stop do
  disabled_switches = [nil, 'false'].freeze

  context 'with an existing Bandwidth channel' do
    let(:channel) { with_modified_env('TOYBACO_SMS_ENABLED' => 'true') { create(:channel_sms) } }
    let(:message) { outgoing_provider_message(channel) }

    disabled_switches.each do |disabled|
      it "stops message and text sends when SMS becomes #{disabled.inspect}" do
        outgoing = message
        with_modified_env('TOYBACO_SMS_ENABLED' => disabled) do
          expect_unavailable { channel.send_message('+15555550101', outgoing) }
          expect_unavailable { channel.send_text_message('+15555550101', 'fixture') }
        end

        expect_no_provider_requests
      end
    end

    it 'sends through Bandwidth when explicitly enabled' do
      request = stub_provider_request(:post, 'https://messaging.bandwidth.com/api/v2/users/1/messages', { id: 'bandwidth-fixture' })
      with_modified_env('TOYBACO_SMS_ENABLED' => 'true') do
        expect(channel.send_message('+15555550101', message)).to eq('bandwidth-fixture')
        expect(channel.send_text_message('+15555550101', 'fixture')).to eq('bandwidth-fixture')
      end

      expect(request).to have_been_requested.twice
    end
  end

  context 'with an existing X channel' do
    let(:channel) { with_modified_env('TOYBACO_TWITTER_ENABLED' => 'true') { create(:channel_twitter_profile) } }

    disabled_switches.each do |disabled|
      it "stops X client creation when the switch becomes #{disabled.inspect}" do
        existing = channel
        with_modified_env('TOYBACO_TWITTER_ENABLED' => disabled) { expect_unavailable { existing.twitter_client } }

        expect_no_provider_requests
      end
    end

    it 'reaches X through the real facade when explicitly enabled' do
      request = stub_provider_request(:get, %r{\Ahttps://api\.twitter\.com/}, {}, status: 204)
      with_modified_env('TOYBACO_TWITTER_ENABLED' => 'true', 'TWITTER_ENVIRONMENT' => 'fixture',
                        'TWITTER_CONSUMER_KEY' => 'fixture', 'TWITTER_CONSUMER_SECRET' => 'fixture') do
        channel.twitter_client.fetch_subscriptions
      end

      expect(request).to have_been_requested.once
    end
  end
end
