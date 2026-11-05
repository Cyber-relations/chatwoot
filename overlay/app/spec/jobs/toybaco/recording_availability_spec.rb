# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Twilio recording availability', :provider_stop, if: ChatwootApp.enterprise?, type: :job do
  switches = %w[TOYBACO_SMS_ENABLED TOYBACO_WHATSAPP_ENABLED].freeze
  disabled_switches = [nil, 'false'].freeze
  let(:channel) { available_twilio('whatsapp') }
  let(:message) { outgoing_provider_message(channel) }
  let(:call) { create(:call, conversation: message.conversation, message: message, recording_enabled: true) }
  let(:url) { 'https://api.twilio.com/2010-04-01/Accounts/AC1/Recordings/REfixture' }
  let(:job) { Voice::Provider::Twilio::RecordingAttachmentJob }
  let(:service) do
    Voice::Provider::Twilio::RecordingAttachmentService.new(call: call, recording_sid: 'REfixture', recording_url: url)
  end

  before do
    allow(Rails.logger).to receive(:warn)
    allow(SafeFetch).to receive(:fetch).and_call_original
  end

  shared_examples 'a stopped recording' do |switch, disabled|
    it "skips recording with #{switch}=#{disabled.inspect}, including the retained service" do
      retained = service
      before_state = message.reload.attributes
      with_provider_switches('true') do
        with_modified_env(switch => disabled) do
          expect_no_job_effects(job, call.id, 'REfixture', url, '47')
          expect_unavailable { retained.perform }
        end
      end

      expect(SafeFetch).not_to have_received(:fetch)
      expect(call.reload.recording).not_to be_attached
      expect(message.reload.attributes).to eq(before_state)
      expect_provider_skip_log
      expect_no_provider_requests
    end
  end

  switches.each do |switch|
    disabled_switches.each { |disabled| it_behaves_like 'a stopped recording', switch, disabled }
  end

  it 'attaches, touches and enqueues transcription when explicitly enabled' do
    call
    before_touch = message.reload.updated_at
    Tempfile.create(['recording', '.mp3'], binmode: true) do |file|
      # Real audio: with the attachment policy, recordings are identified by content.
      file.write(Rails.root.join('spec/assets/sample.mp3').binread)
      file.rewind
      result = SafeFetch::Result.new(tempfile: file, filename: 'recording.mp3', content_type: 'audio/mpeg')
      allow(SafeFetch).to receive(:fetch).with(url, http_basic_authentication: [channel.account_sid, channel.auth_token],
                                                    allowed_content_type_prefixes: %w[audio/]).and_yield(result)
      travel 1.second do
        with_provider_switches('true') do
          expect { job.perform_now(call.id, 'REfixture', url, '47') }.to have_enqueued_job(Voice::CallTranscriptionJob).with(call.id)
        end
      end
    end

    expect(SafeFetch).to have_received(:fetch).once
    expect(call.reload.recording).to be_attached
    expect(call).to have_attributes(recording_sid: 'REfixture', duration_seconds: 47)
    expect(message.reload.updated_at).to be > before_touch
  end
end
