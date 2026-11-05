# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Voice::RecordingStatusService', type: :service do
  # With the channel availability stops, recordings run only while the SMS/voice
  # switch is on; this file exercises that offered path (no effect without them).
  around { |example| with_modified_env('TOYBACO_SMS_ENABLED' => 'true') { example.run } }

  include_context 'without toybaco network connections'

  let(:account) { create(:account) }
  # Twilio voice is not offered; open its switch only to create the fixture channel.
  let(:channel) { with_modified_env('TOYBACO_SMS_ENABLED' => 'true') { create(:channel_twilio_sms, :with_voice, account: account) } }
  let(:conversation) { create(:conversation, account: account, inbox: channel.inbox) }
  let(:call) { create(:call, conversation: conversation, meta: { 'twilio_conference_sid' => 'CFsynthetic', 'recording_enabled' => true }) }
  let(:payload) do
    { 'RecordingStatus' => 'completed', 'ConferenceSid' => 'CFsynthetic', 'RecordingSid' => 'REsynthetic',
      'RecordingUrl' => 'https://example.test/recording', 'RecordingDuration' => '12' }
  end

  before do
    allow(Twilio::VoiceWebhookSetupService).to receive(:new)
      .and_return(instance_double(Twilio::VoiceWebhookSetupService, perform: 'APsynthetic'))
    call
    allow(Voice::CallTranscriptionJob).to receive(:perform_later)
    allow(ActiveStorage::Blob.service).to receive(:upload).and_call_original
  end

  def deliver_recording(bytes)
    result = SafeFetch::Result.new(tempfile: StringIO.new(bytes), filename: 'recording.wav', content_type: 'audio/wav')
    allow(SafeFetch).to receive(:fetch).and_yield(result)
    expect do
      Voice::RecordingStatusService.new(account: account, payload: payload).perform
    end.to have_enqueued_job(Voice::Provider::Twilio::RecordingAttachmentJob)
      .with(call.id, 'REsynthetic', 'https://example.test/recording', '12')
    # The block form asserts that nothing raises and masks expected rejections
    # with Rails' Minitest-only tagged_logger helper. Flush the actual job instead.
    perform_enqueued_jobs(only: Voice::Provider::Twilio::RecordingAttachmentJob)
  end

  ['<html><script>blocked()</script></html>', "\x00\x01\x02binary".b].each_with_index do |bytes, index|
    it "rejects audio-labelled forbidden response #{index + 1} without uploading or transcribing" do
      expect do
        expect { deliver_recording(bytes) }.to raise_error(Toybaco::Security::AttachmentPolicy::Rejected)
      end.not_to change(ActiveStorage::Blob, :count)

      expect(call.reload.recording).not_to be_attached
      expect(call.recording_sid).to be_nil
      expect(call.duration_seconds).to be_nil
      expect(ActiveStorage::Blob.service).not_to have_received(:upload)
      expect(Voice::CallTranscriptionJob).not_to have_received(:perform_later)
    end
  end

  it 'preserves real WAV bytes through the status callback, job and recording service' do
    bytes = Rails.root.join('spec/assets/toybaco/attachment_formats/recording.wav').binread
    deliver_recording(bytes)

    expect(call.reload.recording).to be_attached
    expect(call.recording.content_type).to eq('audio/x-wav')
    call.recording.open { |io| expect(io.read).to eq(bytes) }
    expect(call.recording_sid).to eq('REsynthetic')
    expect(call.duration_seconds).to eq(12)
    expect(ActiveStorage::Blob.service).to have_received(:upload).once
    expect(Voice::CallTranscriptionJob).to have_received(:perform_later).with(call.id).once
  end
end
