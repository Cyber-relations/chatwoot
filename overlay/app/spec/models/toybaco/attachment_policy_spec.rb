# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Attachment do
  include_context 'without toybaco network connections'
  let(:account) { create(:account) }
  let(:inbox) { create(:channel_telegram, account: account).inbox }
  let(:message) { build(:message, account: account, inbox: inbox, content: 'Synthetic received message', message_type: :incoming) }
  let(:html) { '<!doctype html><html><script>alert(1)</script></html>' }

  def attach(bytes, filename: 'disguised.png', type: 'image/png')
    message.attachments.build(account: account, file_type: :image, file: { io: StringIO.new(bytes), filename: filename, content_type: type })
  end

  it 'keeps the received message and filename while never saving the forbidden file' do
    attachment = attach(html)
    allow(ActiveStorage::Blob.service).to receive(:upload).and_call_original
    expect { message.save! }.not_to change(ActiveStorage::Blob, :count)

    expect(message.reload.content).to eq('Synthetic received message')
    expect(attachment.reload.file).not_to be_attached
    expect(attachment.push_event_data).to include(file_type: 'fallback', fallback_title: a_string_including('File not kept', 'disguised.png'))
    expect(message.content_attributes['rejected_attachments']).to include(include('filename' => 'disguised.png'))
    expect(ActiveStorage::Blob.service).not_to have_received(:upload)
  end

  it 'handles the late file.attach path used by Messenger without losing the original message' do
    message.save!
    attachment = message.attachments.create!(account: account, file_type: :image, external_url: 'https://example.test/remote')
    expect do
      attachment.file.attach(io: StringIO.new(html), filename: 'remote.html', content_type: 'image/png')
    end.not_to change(ActiveStorage::Blob, :count)

    expect(attachment.reload).to be_fallback
    expect(attachment.external_url).to be_nil
    expect(attachment.file).not_to be_attached
    expect(message.reload.content).to eq('Synthetic received message')
    expect(message.content_attributes['rejected_attachments']).to include(include('filename' => 'remote.html'))
  end

  it 'keeps both rejected filenames and an allowed file in one received message' do
    attach(html, filename: 'first.html')
    attach('<svg xmlns="http://www.w3.org/2000/svg"/>', filename: 'second.svg')
    attach('Synthetic text', filename: 'allowed.txt', type: 'text/plain')
    message.save!

    expect(message.reload.attachments.map { |item| item.file.attached? }).to eq([false, false, true])
    expect(message.content_attributes['rejected_attachments'].pluck('filename')).to contain_exactly('first.html', 'second.svg')
    expect(message.attachments.last.file.content_type).to eq('text/plain')
  end

  it 'does not restore rejected filenames when the message is deleted' do
    attach(html, filename: 'removed.html')
    message.save!
    message.update!(content: 'Message deleted', content_attributes: { deleted: true })
    message.attachments.destroy_all

    expect(message.reload.content_attributes).to eq('deleted' => true)
  end

  it 'removes the retained names when a provider marks the message deleted' do
    attach(html, filename: 'removed.html')
    message.save!
    message.attachments.destroy_all
    message.update!(content: 'Message deleted', deleted: true)

    expect(message.reload.content_attributes['rejected_attachments']).to be_nil
  end

  it 'rejects a forbidden dashboard/API attachment on an outgoing email message' do
    email_inbox = create(:channel_email, account: account).inbox
    conversation = create(:conversation, account: account, inbox: email_inbox)
    agent = create(:user, account: account)
    params = { content: 'Synthetic API input', message_type: 'outgoing' }
    # Use the builder entry with a real UploadedFile, as the HTTP controller does.
    Tempfile.create('attachment-spec') do |file|
      file.write(html)
      file.rewind
      params[:attachments] = [ActionDispatch::Http::UploadedFile.new(tempfile: file, filename: 'bad.png', type: 'image/png')]
      expect { Messages::MessageBuilder.new(agent, conversation, params).perform }.to raise_error(ActiveRecord::RecordInvalid) { |error|
        expect(error.record).to be_a(Message)
        expect(error.record.attachments.sole.errors[:file]).to include('File type not supported')
      }
    end
  end

  it 'omits oversized received attachments using the existing configured limit' do
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('MAXIMUM_FILE_UPLOAD_SIZE', 40).and_return(1)
    attachment = attach('a' * (1.megabyte + 1), filename: 'large.txt', type: 'text/plain')
    message.save!

    expect(attachment.reload.file).not_to be_attached
    expect(attachment.fallback_title).to include('large.txt', 'size is too big')
    expect(message.reload.content).to eq('Synthetic received message')
  end

  %w[avatar.png attachment.pdf sample.mp3 sample.ogg sample.mp4 sample.mov].each do |fixture|
    it "keeps allowed #{fixture} bytes despite a misleading client MIME" do
      attachment = attach(Rails.root.join('spec/assets', fixture).binread, filename: fixture, type: 'application/octet-stream')
      message.save!

      expect(attachment.reload.file).to be_attached
      expect(attachment.file.content_type).not_to eq('application/octet-stream')
      expect(message.reload.content_attributes['rejected_attachments']).to be_nil
    end
  end

  context 'with MP4 attachments' do
    %w[isom mp42].each do |brand|
      it "retains audio classification and enqueues transcription for an audio-only #{brand} MP4" do
        bytes = Rails.root.join('spec/assets/toybaco/attachment_formats', "audio-#{brand}.m4a").binread
        attachment = attach(bytes, filename: 'voice.m4a', type: 'audio/mp4')
        attachment.file_type = :audio
        allow(Messages::AudioTranscriptionJob).to receive(:perform_later)
        message.save!

        expect(attachment.reload).to be_audio
        expect(attachment.file.content_type).to eq('audio/mp4')
        expect(Messages::AudioTranscriptionJob).to have_received(:perform_later).with(attachment.id)
      end
    end

    it 'classifies a real video as video even when declared and assigned as audio' do
      bytes = Rails.root.join('spec/assets/toybaco/attachment_formats/video-mp42.mp4').binread
      attachment = attach(bytes, filename: 'voice.m4a', type: 'audio/mp4')
      attachment.file_type = :audio
      allow(Messages::AudioTranscriptionJob).to receive(:perform_later)
      message.save!

      expect(attachment.reload).to be_video
      expect(attachment.file.content_type).to eq('video/mp4')
      expect(Messages::AudioTranscriptionJob).not_to have_received(:perform_later)
    end

    { 'audio-isom.m4a' => 'audio', 'audio-mp42.m4a' => 'audio', 'video-mp42.mp4' => 'video' }.each do |fixture, media_type|
      it "sends #{fixture} with the #{media_type} WhatsApp message type" do
        bytes = Rails.root.join('spec/assets/toybaco/attachment_formats', fixture).binread
        attachment = attach(bytes, filename: 'voice.m4a', type: 'audio/mp4')
        attachment.file_type = :audio
        message.message_type = :outgoing
        message.save!
        channel = build(:channel_whatsapp, account: account, provider: 'whatsapp_cloud')
        upload = instance_double(Whatsapp::MediaUploadService, perform: { 'id' => 'synthetic-media' })
        allow(Whatsapp::MediaUploadService).to receive(:new).with(channel, attachment).and_return(upload)
        request = stub_request(:post, 'https://graph.facebook.com/v24.0/random_id/messages')
                  .with(body: hash_including('type' => media_type, media_type => hash_including('id' => 'synthetic-media')))
                  .to_return(status: 200, body: { messages: [{ id: 'synthetic-message' }] }.to_json,
                             headers: { 'Content-Type' => 'application/json' })

        service = Whatsapp::Providers::WhatsappCloudService.new(whatsapp_channel: channel)
        # The provider stop sends only while WhatsApp is on (no effect without the stop).
        sent = with_modified_env('TOYBACO_WHATSAPP_ENABLED' => 'true') { service.send_message('+15555550100', message.reload) }
        expect(sent).to eq('synthetic-message')
        expect(request).to have_been_requested.once
      end
    end
  end

  # These are the other audio signatures in Marcel 1.1.0's Ogg magic table.
  { 'Speex   ' => 'audio/speex', 'FLAC' => 'audio/x-oggflac', 'PCM     ' => 'audio/x-oggpcm' }.each do |signature, type|
    it "accepts the pinned #{type} Ogg detection" do
      bytes = 'OggS'.b + ("\x00" * 24) + signature
      expect(Marcel::MimeType.for(StringIO.new(bytes))).to eq(type)
      attachment = attach(bytes, filename: 'voice.ogg', type: 'audio/ogg')
      message.save!
      expect(attachment.reload.file.content_type).to eq(type)
      expect(message.reload.content_attributes['rejected_attachments']).to be_nil
    end
  end

  %w[archive.zip document.docx document.odt].each do |fixture|
    it "accepts the #{fixture} container based on bytes with no filename or client MIME help" do
      bytes = Rails.root.join('spec/assets/toybaco/attachment_formats', fixture).binread
      attachment = attach(bytes, filename: 'no-extension', type: 'application/octet-stream')
      message.save!

      expect(attachment.reload.file).to be_attached
      expect(attachment.file.content_type).not_to eq('application/octet-stream')
      expect(message.reload.content_attributes['rejected_attachments']).to be_nil
    end
  end

  { 'docx' => 'wordprocessingml.document', 'xlsx' => 'spreadsheetml.sheet', 'pptx' => 'presentationml.presentation' }.each do |extension, subtype|
    it "preserves a received #{extension} whose subtype marker is beyond Marcel's sniff window" do
      bytes = Rails.root.join('spec/assets/toybaco/attachment_formats', "late-marker.#{extension}").binread
      expect(Marcel::MimeType.for(StringIO.new(bytes))).to eq('application/x-tika-ooxml')
      attachment = attach(bytes, filename: 'untrusted.bin', type: 'application/octet-stream')
      message.save!

      expect(attachment.reload.file).to be_attached
      expect(attachment.file.content_type).to eq("application/vnd.openxmlformats-officedocument.#{subtype}")
      attachment.file.open { |io| expect(io.read).to eq(bytes) }
      expect(message.reload.content_attributes['rejected_attachments']).to be_nil
    end
  end

  it 'keeps a received Office package as ZIP when subtype inspection reaches its bound' do
    stub_const('Toybaco::Security::OfficeZipDirectory::MAX_MEMBER_BYTES', 16)
    bytes = Rails.root.join('spec/assets/toybaco/attachment_formats/late-marker.docx').binread
    attachment = attach(bytes, filename: 'document.docx')
    message.save!

    expect(attachment.reload.file.content_type).to eq('application/zip')
    attachment.file.open { |io| expect(io.read).to eq(bytes) }
    expect(message.reload.content_attributes['rejected_attachments']).to be_nil
  end

  ['plain text', "column,value\nsynthetic,1\n", '日本語のCSV,値'.encode(Encoding::Windows_31J)].each_with_index do |bytes, index|
    it "accepts text/CSV bytes #{index + 1} without trusting the declared MIME" do
      attachment = attach(bytes, filename: 'report.csv', type: 'application/octet-stream')
      message.save!
      expect(attachment.reload.file.content_type).to eq('text/plain')
    end
  end

  ["MZ\x00\x01synthetic executable".b, "\x00\x01\x02\x03unknown binary".b,
   '<svg xmlns="http://www.w3.org/2000/svg"/>', '    <!-- disguised --><script>alert(1)</script>'].each_with_index do |bytes, index|
    it "rejects disallowed bytes #{index + 1} even with an allowed extension and MIME" do
      attachment = attach(bytes)
      message.save!
      expect(attachment.reload.file).not_to be_attached
      expect(attachment).to be_fallback
    end
  end

  it 'rejects markup encoded as UTF-16 rather than accepting it as text' do
    attachment = attach("\xFF\xFE".b + html.encode(Encoding::UTF_16LE).b, filename: 'report.txt', type: 'text/plain')
    message.save!
    expect(attachment.reload.file).not_to be_attached
    expect(attachment).to be_fallback
  end

  it 'keeps non-file attachments such as locations working' do
    attachment = message.attachments.build(account: account, file_type: :location, coordinates_lat: 35, coordinates_long: 139)
    message.save!
    expect(attachment.reload).to be_location
    expect(message.reload.content_attributes['rejected_attachments']).to be_nil
  end

  it 'records names for SMS files that upstream silently skipped by URL extension' do
    inbox = with_modified_env('TOYBACO_SMS_ENABLED' => 'true') { create(:channel_sms, account: account) }.inbox
    sms_message = build(:message, account: account, inbox: inbox)
    service = Sms::IncomingMessageService.new(inbox: inbox, params: { media: ['https://example.test/message.xml'] })
    service.instance_variable_set(:@message, sms_message)
    allow(service).to receive(:download_media).and_yield(StringIO.new('<smil>synthetic</smil>'), 'message.xml', 'application/xml')
    service.send(:attach_files)
    sms_message.save!

    expect(sms_message.reload.content_attributes['rejected_attachments']).to include(include('filename' => 'message.xml'))
    expect(sms_message.attachments.first.file).not_to be_attached
  end
end
