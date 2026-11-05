# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Inbound provider availability', :provider_stop, type: :job do
  targets = {
    cloud: ['Webhooks::WhatsappEventsJob', 'TOYBACO_WHATSAPP_ENABLED', 'wamid.inbound'],
    bandwidth: ['Webhooks::SmsEventsJob', 'TOYBACO_SMS_ENABLED', 'bandwidth-inbound'],
    twilio_sms: ['Webhooks::TwilioEventsJob', 'TOYBACO_SMS_ENABLED', 'SMinbound'],
    twilio_whatsapp: ['Webhooks::TwilioEventsJob', 'TOYBACO_WHATSAPP_ENABLED', 'SMinbound']
  }.freeze
  disabled_switches = [nil, 'false'].freeze
  prefix_keys = %i[To From].freeze
  key_formats = %i[string symbol].freeze

  before { allow(Rails.logger).to receive(:warn) }

  shared_examples 'a stopped inbound event' do |kind, name, switch, disabled|
    it "skips #{kind} media when its switch becomes #{disabled.inspect}" do
      channel = available_provider(kind)
      payload = add_provider_event_media(kind, provider_event_payload(kind, channel))
      before_state = provider_event_snapshot(channel)
      with_provider_switches('true') do
        with_modified_env(switch => disabled) { expect_no_job_effects(name.constantize, payload) }
      end

      expect(provider_event_snapshot(channel)).to eq(before_state)
      expect_provider_skip_log
      expect_no_provider_requests
    end
  end

  shared_examples 'an enabled inbound event' do |kind, name, source_id|
    it "processes #{kind} text when explicitly enabled" do
      channel = available_provider(kind)
      payload = provider_event_payload(kind, channel)
      with_provider_switches('true') { expect_no_job_retry(name.constantize, payload) }

      expect(channel.inbox.messages.find_by(source_id: source_id)).to have_attributes(content: 'fixture', message_type: 'incoming')
    end
  end

  targets.each do |kind, (name, switch, source_id)|
    disabled_switches.each { |disabled| it_behaves_like 'a stopped inbound event', kind, name, switch, disabled }
    it_behaves_like 'an enabled inbound event', kind, name, source_id
  end

  shared_examples 'Twilio indifferent prefix detection' do |key, key_format, disabled|
    it "detects WhatsApp from #{key} with #{key_format} keys and switch #{disabled.inspect}" do
      channel = available_twilio('whatsapp')
      payload = twilio_event_payload(channel)
      payload[:To] = payload[:To].delete_prefix('whatsapp:')
      payload[:From] = '+15555550101'
      payload[key] = "whatsapp:#{payload[key]}"
      payload = key_format == :string ? payload.to_h : payload.to_h.symbolize_keys
      with_modified_env('TOYBACO_SMS_ENABLED' => 'true', 'TOYBACO_WHATSAPP_ENABLED' => disabled) do
        expect_no_job_effects(Webhooks::TwilioEventsJob, payload)
      end

      expect_provider_skip_log
      expect_no_provider_requests
    end
  end

  prefix_keys.each do |key|
    key_formats.each do |key_format|
      disabled_switches.each { |disabled| it_behaves_like 'Twilio indifferent prefix detection', key, key_format, disabled }
    end
  end

  context 'with Enterprise call events', if: ChatwootApp.enterprise? do
    let(:channel) { available_whatsapp }
    let(:payload) do
      event = whatsapp_event_payload(channel, 'calls')
      event.dig(:entry, 0, :changes, 0, :value)[:calls] = [{ id: 'call-fixture', event: 'connect', session: { sdp_type: 'offer' } }]
      event
    end

    shared_examples 'a stopped Enterprise call event' do |disabled|
      it "stops before the Enterprise handler when WhatsApp becomes #{disabled.inspect}" do
        event = payload
        allow(Whatsapp::IncomingCallService).to receive(:new).and_call_original
        with_modified_env('TOYBACO_WHATSAPP_ENABLED' => disabled) { expect_no_job_effects(Webhooks::WhatsappEventsJob, event) }

        expect(Whatsapp::IncomingCallService).not_to have_received(:new)
        expect_provider_skip_log
        expect_no_provider_requests
      end
    end

    disabled_switches.each { |disabled| it_behaves_like 'a stopped Enterprise call event', disabled }

    it 'reaches the Enterprise handler when explicitly enabled' do
      service = instance_spy(Whatsapp::IncomingCallService)
      allow(Whatsapp::IncomingCallService).to receive(:new).and_return(service)
      with_provider_switches('true') { Webhooks::WhatsappEventsJob.perform_now(payload) }

      expect(service).to have_received(:perform).once
    end
  end
end
