# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Toybaco::ChannelAvailability::ProviderGuard, :provider_stop do
  disabled_switches = [nil, 'false'].freeze
  providers = %w[whatsapp_cloud default].freeze

  providers.each do |provider|
    context "with an existing #{provider} channel" do
      let(:channel) { available_whatsapp(provider) }
      let(:message) { outgoing_provider_message(channel) }
      let(:service) { Whatsapp::SendOnWhatsappService.new(message: message) }
      let(:message_url) do
        provider == 'whatsapp_cloud' ? 'https://graph.facebook.com/v13.0/123456789/messages' : 'https://waba.360dialog.io/v1/messages'
      end

      disabled_switches.each do |disabled|
        it "stops outgoing replies when the switch becomes #{disabled.inspect}" do
          service
          with_modified_env('TOYBACO_WHATSAPP_ENABLED' => disabled) { expect_unavailable { service.perform } }

          expect(message.reload.source_id).to be_nil
          expect_no_provider_requests
        end

        it "stops a retained provider when the switch becomes #{disabled.inspect}" do
          retained = with_modified_env('TOYBACO_WHATSAPP_ENABLED' => 'true') { channel.provider_service }
          outgoing = message
          with_modified_env('TOYBACO_WHATSAPP_ENABLED' => disabled) do
            expect_unavailable { retained.send_message('15555550101', outgoing) }
          end

          expect_no_provider_requests
        end
      end

      it 'sends a reply through the provider when explicitly enabled' do
        request = stub_provider_request(:post, message_url, { messages: [{ id: 'wamid.fixture' }] })
        with_modified_env('TOYBACO_WHATSAPP_ENABLED' => 'true') { service.perform }

        expect(request).to have_been_requested.once
        expect(message.reload.source_id).to eq('wamid.fixture')
      end
    end
  end
end
