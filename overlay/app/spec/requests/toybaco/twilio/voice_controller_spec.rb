# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Twilio::VoiceController, type: :request do
  let(:channel) do
    with_modified_env('TOYBACO_SMS_ENABLED' => 'true') do
      create(:channel_twilio_sms, :with_voice, provider_config: { 'inbound_calls_enabled' => true })
    end
  end
  let(:conversation) { create(:conversation, account: channel.account, inbox: channel.inbox) }
  let!(:call) do
    create(:call, conversation: conversation, provider_call_id: 'CA_fixture',
                  conference_sid: 'fixture-conference', twilio_conference_sid: 'CF_fixture')
  end
  let(:records) { [Call, Conversation, Message, Contact, ContactInbox, Inbox, Channel::TwilioSms, ActiveStorage::Attachment, ActiveStorage::Blob] }
  let(:payload) do
    {
      Direction: 'inbound', From: '+15555550101', To: channel.phone_number, CallSid: call.provider_call_id,
      CallStatus: 'completed', StatusCallbackEvent: 'conference-end', FriendlyName: call.conference_sid,
      ConferenceSid: call.twilio_conference_sid, RecordingStatus: 'completed', RecordingSid: 'RE_fixture',
      RecordingUrl: 'https://example.invalid/private-recording', RecordingDuration: '10'
    }
  end

  before do
    allow(Rails.logger).to receive(:warn)
  end

  actions = %w[call status conference_status recording_status]

  [nil, 'false'].each do |disabled|
    context "when SMS is #{disabled.inspect}, even with WhatsApp enabled" do
      around do |example|
        with_modified_env('TOYBACO_SMS_ENABLED' => disabled, 'TOYBACO_WHATSAPP_ENABLED' => 'true') { example.run }
      end

      actions.each do |action|
        it "rejects unsigned #{action} before lookup, without records, updates, jobs or provider calls" do
          expect(channel.voice_enabled?).to be(true)
          expect(channel.inbound_calls_enabled?).to be(true)
          expect(Twilio::REST::Client).not_to receive(:new)
          expect_no_voice_processing

          previous_call = call.attributes
          request_payload = action == 'call' ? payload.merge(CallSid: 'CA_forged') : payload
          expect do
            post "/twilio/voice/#{action}/#{channel.phone_number.delete_prefix('+')}", params: request_payload
          end.not_to(change { records.map(&:count) })

          expect(response).to have_http_status(:not_found)
          expect(call.reload.attributes).to eq(previous_call)
          expect(Rails.logger).to have_received(:warn).with('Toybaco webhook rejected: voice channel is not offered').once
        end
      end

      it 'does not infer the voice policy from spoofed WhatsApp numbers' do
        expect(channel.voice_enabled?).to be(true)
        expect(channel.inbound_calls_enabled?).to be(true)
        expect(Twilio::REST::Client).not_to receive(:new)
        expect_no_voice_processing

        post "/twilio/voice/call/#{channel.phone_number.delete_prefix('+')}",
             params: payload.merge(From: 'whatsapp:+15555550101', To: 'whatsapp:+15555550202')

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  it 'leaves the upstream status action reachable when SMS is explicitly enabled' do
    expect(channel.voice_enabled?).to be(true)
    expect(channel.inbound_calls_enabled?).to be(true)
    expect(Twilio::REST::Client).not_to receive(:new)
    service = instance_double(Voice::StatusUpdateService, perform: nil)
    allow(Voice::StatusUpdateService).to receive(:new).and_return(service)

    with_modified_env('TOYBACO_SMS_ENABLED' => 'true', 'TOYBACO_WHATSAPP_ENABLED' => nil) do
      post "/twilio/voice/status/#{channel.phone_number.delete_prefix('+')}", params: payload
    end

    expect(response).to have_http_status(:no_content)
    expect(service).to have_received(:perform).once
  end

  def expect_no_voice_processing
    expect(Channel::TwilioSms).not_to receive(:find_by!)
    expect(Voice::InboundCallBuilder).not_to receive(:perform!)
    expect(Voice::StatusUpdateService).not_to receive(:new)
    expect(Voice::Conference::Manager).not_to receive(:new)
    expect(Voice::RecordingStatusService).not_to receive(:new)
    expect(ActiveJob::Base.queue_adapter).not_to receive(:enqueue)
    expect(ActiveJob::Base.queue_adapter).not_to receive(:enqueue_at)
  end
end
