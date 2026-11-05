# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Toybaco::Security::AttachmentMail do
  include_context 'without toybaco network connections'

  let(:account) { create(:account) }
  let(:channel) { create(:channel_email, account: account) }

  def binary_part(bytes, filename, type, disposition)
    <<~PART
      Content-Type: #{type}; name=#{filename}
      Content-Disposition: #{disposition}; filename=#{filename}
      Content-ID: <root>
      Content-Transfer-Encoding: base64

      #{Base64.strict_encode64(bytes)}
    PART
  end

  def related_source(bytes, filename:, type:, start:, disposition: 'inline')
    root = binary_part(bytes, filename, type, disposition)
    companion = "Content-Type: text/plain; name=companion.txt\nContent-Disposition: attachment; filename=companion.txt\n\nCompanion\n"
    parts = start ? [companion, root] : [root, companion]
    related = "Content-Type: multipart/related; boundary=related#{start ? '; start="<root>"' : ''}\n" \
              "Content-Disposition: inline\nContent-ID: <container>\n\n" \
              "#{parts.map { |part| "--related\n#{part}" }.join}--related--\n"
    source = "From: synthetic@example.test\nTo: #{channel.email}\nSubject: Related root\n" \
             "Message-ID: <#{SecureRandom.uuid}@example.test>\nMIME-Version: 1.0\nContent-Type: multipart/mixed; boundary=outer\n\n" \
             "--outer\nContent-Type: text/plain\n\nKeep this message\n--outer\n#{related}\n--outer--\n"
    source.gsub("\n", "\r\n")
  end

  formats = { 'avatar.png' => 'image/png', 'sample.pdf' => 'application/pdf' }
  [false, true].product(formats.to_a, %w[inline attachment]).each do |start, (fixture, type), disposition|
    it "keeps #{disposition} #{fixture} as a visible related-root attachment with start=#{start}" do
      bytes = Rails.root.join('spec/assets', fixture).binread
      source = related_source(bytes, filename: fixture, type: type, start: start, disposition: disposition)
      inbound = ActionMailbox::InboundEmail.create_and_extract_message_id!(source)
      inbound.raw_email.blob.open do |io|
        expect(Mail.read_from_string(io.read).attachments[fixture].body.decoded).to eq(bytes)
      end
      Imap::ImapMailbox.new.process(inbound.mail, channel)
      message = channel.inbox.messages.find_by!(source_id: inbound.mail.message_id)
      attachment = message.attachments.find { |item| item.file.filename.to_s == fixture }

      expect(message.content).to include('Keep this message')
      expect(attachment).to be_present
      expect(attachment.file.content_type).to eq(type)
      attachment.file.open { |io| expect(io.read).to eq(bytes) }
      expect(message.attachments.map { |item| item.file.filename.to_s }).to contain_exactly(fixture, 'companion.txt')
      expect(message.content_attributes['rejected_attachments']).to be_blank
    end
  end

  [false, true].each do |start|
    it "rejects a binary root attachment and keeps its explicit text companion with start=#{start}" do
      bytes = "MZ\x00\x01forbidden-related-root".b
      source = related_source(bytes, filename: 'root.exe', type: 'application/octet-stream', start: start)
      inbound = ActionMailbox::InboundEmail.create_and_extract_message_id!(source)
      inbound.raw_email.blob.open { |io| expect(io.read).to eq(source) }
      Imap::ImapMailbox.new.process(inbound.mail, channel)
      message = channel.inbox.messages.find_by!(source_id: inbound.mail.message_id)

      expect(message.content).to include('Keep this message')
      expect(message.content_attributes['rejected_attachments']).to include(include('filename' => 'root.exe'))
      expect(ActiveStorage::Blob.where(filename: 'root.exe')).not_to exist
      expect(message.attachments.sole.file.filename.to_s).to eq('companion.txt')
      message.attachments.sole.file.open { |io| expect(io.read).to start_with('Companion') }
    end
  end

  { 'customers.csv' => "name,email\nCustomer <customer@example.test>,customer@example.test\n", 'report.txt' => 'x<y' }.each do |filename, bytes|
    it "preserves ordinary angle brackets in #{filename} through raw source and message storage" do
      mail = Mail.new(from: 'synthetic@example.test', to: channel.email, subject: 'Text preservation')
      mail.message_id = "#{SecureRandom.uuid}@example.test"
      mail.text_part = Mail::Part.new(body: 'Keep this message')
      mail.attachments[filename] = { mime_type: 'text/plain', content: bytes }
      inbound = ActionMailbox::InboundEmail.create_and_extract_message_id!(mail.encoded)
      inbound.raw_email.blob.open do |io|
        expect(Mail.read_from_string(io.read).attachments[filename].body.decoded).to eq(bytes)
      end
      Imap::ImapMailbox.new.process(inbound.mail, channel)
      message = channel.inbox.messages.find_by!(source_id: inbound.mail.message_id)

      message.attachments.sole.file.open { |io| expect(io.read).to eq(bytes) }
      expect(message.content_attributes['rejected_attachments']).to be_blank
    end
  end
end
