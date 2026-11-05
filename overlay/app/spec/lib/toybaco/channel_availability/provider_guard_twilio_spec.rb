# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Toybaco::ChannelAvailability::ProviderGuard, :provider_stop do
  disabled_switches = [nil, 'false'].freeze

  %w[sms whatsapp].each do |medium|
    context "with an existing Twilio #{medium} channel" do
      let(:channel) { available_twilio(medium) }
      let(:switch) { medium == 'sms' ? 'TOYBACO_SMS_ENABLED' : 'TOYBACO_WHATSAPP_ENABLED' }
      let(:message) { outgoing_provider_message(channel) }
      let(:service) { Twilio::SendOnTwilioService.new(message: message) }

      disabled_switches.each do |disabled|
        it "stops client creation when the type switch becomes #{disabled.inspect}" do
          existing = channel
          with_modified_env(switch => disabled) { expect_unavailable { existing.client } }

          expect_no_provider_requests
        end

        it "stops outgoing messages when the type switch becomes #{disabled.inspect}" do
          service
          with_modified_env(switch => disabled) { expect_unavailable { service.perform } }

          expect(message.reload.source_id).to be_nil
          expect_no_provider_requests
        end

        it "stops direct CSAT HTTP calls when the type switch becomes #{disabled.inspect}" do
          client = Twilio::CsatTemplateApiClient.new(channel)
          with_modified_env(switch => disabled) { expect_unavailable { client.fetch_template('HXfixture') } }

          expect_no_provider_requests
        end
      end

      it 'sends through the real SDK when its type is enabled and the other type is off' do
        request = stub_provider_request(:post, %r{\Ahttps://api\.twilio\.com/2010-04-01/Accounts/AC1+/Messages.json},
                                        { sid: 'SMfixture' }, status: 201)
        service
        with_modified_env('TOYBACO_SMS_ENABLED' => nil, 'TOYBACO_WHATSAPP_ENABLED' => nil) do
          with_modified_env(switch => 'true') { service.perform }
        end

        expect(request).to have_been_requested.once
        expect(message.reload.source_id).to eq('SMfixture')
      end
    end
  end

  context 'with an existing Enterprise voice channel', if: ChatwootApp.enterprise? do
    let(:channel) { available_twilio('sms', voice_enabled: true, twiml_app_sid: 'APfixture', api_key_sid: 'SKfixture', api_key_secret: 'fixture') }

    disabled_switches.each do |disabled|
      it "stops Enterprise client and adapter creation when SMS becomes #{disabled.inspect}" do
        adapter = Voice::Provider::Twilio::Adapter.new(channel)
        with_modified_env('TOYBACO_SMS_ENABLED' => disabled) do
          expect_unavailable { channel.client }
          expect_unavailable { adapter.initiate_call(to: '+15555550101') }
        end

        expect_no_provider_requests
      end
    end
  end
end
