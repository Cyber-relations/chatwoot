# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Call recording content validation', type: :model do
  include_context 'without toybaco network connections'

  let!(:call) { create(:call) }
  let(:audio) { Rails.root.join('spec/assets/toybaco/attachment_formats/recording.wav').binread }

  before { allow(ActiveStorage::Blob.service).to receive(:upload).and_call_original }

  ['<html><script>blocked()</script></html>', "\x00\x01\x02binary".b, 'ordinary text'].each_with_index do |bytes, index|
    it "rejects disguised non-audio input #{index + 1} at the writer before creating an attachment change" do
      expect do
        call.recording = { io: StringIO.new(bytes), filename: 'recording.wav', content_type: 'audio/wav' }
      end.to raise_error(Toybaco::Security::AttachmentPolicy::Rejected)

      expect(call.attachment_changes).not_to have_key('recording')
      expect { call.save! }.not_to change(ActiveStorage::Blob, :count)
      expect(call.reload.recording).not_to be_attached
      expect(ActiveStorage::Blob.service).not_to have_received(:upload)
    end
  end

  it 'rejects video even when its filename and declared type describe audio' do
    bytes = Rails.root.join('spec/assets/toybaco/attachment_formats/video-mp42.mp4').binread
    expect do
      call.recording.attach(io: StringIO.new(bytes), filename: 'voice.m4a', content_type: 'audio/mp4')
    end.to raise_error(Toybaco::Security::AttachmentPolicy::Rejected, 'File must be audio')

    expect(call.reload.recording).not_to be_attached
    expect(ActiveStorage::Blob.service).not_to have_received(:upload)
  end

  it 'stores genuine audio with its detected type and allows detaching it' do
    call.recording.attach(io: StringIO.new(audio), filename: 'recording.bin', content_type: 'application/octet-stream')

    expect(call.reload.recording).to be_attached
    expect(call.recording.content_type).to eq('audio/x-wav')
    call.recording.open { |io| expect(io.read).to eq(audio) }
    expect(ActiveStorage::Blob.service).to have_received(:upload).once
    call.update!(recording: nil)
    expect(call.reload.recording).not_to be_attached
  end

  [:blob, :signed_id].each do |form|
    it "rechecks #{form} bytes even when the blob metadata says it is identified audio" do
      blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new('<html>blocked</html>'), filename: 'recording.wav',
                                                    content_type: 'audio/wav', identify: false)
      blob.update!(metadata: { identified: true, analyzed: true })
      expect do
        call.recording.attach(form == :blob ? blob : blob.signed_id)
      end.to raise_error(Toybaco::Security::AttachmentPolicy::Rejected)

      expect(call.reload.recording).not_to be_attached
      expect(blob.reload.attachments).to be_empty
      expect(ActiveStorage::Blob.service).to have_received(:upload).once # Only the pre-existing fixture blob.
    end
  end

  it 'rejects an oversized recording before storage upload' do
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('MAXIMUM_FILE_UPLOAD_SIZE', 40).and_return(1)
    expect do
      call.recording.attach(io: StringIO.new(audio + ("\x00" * 1.megabyte)), filename: 'large.wav', content_type: 'audio/wav')
    end.to raise_error(Toybaco::Security::AttachmentPolicy::Rejected, 'File size is too big')

    expect(ActiveStorage::Blob.service).not_to have_received(:upload)
  end
end
