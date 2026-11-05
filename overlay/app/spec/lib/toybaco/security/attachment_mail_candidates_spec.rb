# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Toybaco::Security::AttachmentMail do
  include_context 'without toybaco network connections'

  let(:channel) { create(:channel_email) }
  let(:bytes) { "MZ\x00\x01forbidden-attachment".b }

  def source_with_part(headers, payload = bytes, encoded: true, boundary: 'outer')
    <<~MAIL.gsub("\n", "\r\n")
      From: synthetic@example.test
      To: #{channel.email}
      Subject: Attachment candidates
      Message-ID: <#{SecureRandom.uuid}@example.test>
      MIME-Version: 1.0
      Content-Type: multipart/mixed; boundary=#{boundary}

      --#{boundary}
      Content-Type: text/plain

      Keep this message
      --#{boundary}
      #{headers}
      Content-Transfer-Encoding: #{encoded ? 'base64' : '7bit'}

      #{encoded ? Base64.strict_encode64(payload) : payload.gsub("\r\n", "\n")}
      --#{boundary}--
    MAIL
  end

  {
    'named' => ['Content-Disposition: attachment; filename=original.exe', 'original.exe'],
    'blank filename' => ['Content-Disposition: attachment; filename=""', 'attachment'],
    'location without filename' => ['Content-Location: original.exe', 'original.exe']
  }.each do |kind, (header, omitted_name)|
    it "checks the #{kind} upstream candidate before any attachment upload" do
      source = source_with_part("Content-Type: application/octet-stream\n#{header}")
      inbound = ActionMailbox::InboundEmail.create_and_extract_message_id!(source)
      expect(inbound.mail.attachments.size).to eq(1)
      inbound.raw_email.blob.open { |io| expect(io.read).to eq(source) }
      # Raw RFC822 storage is intentional; observe writes after ingress only.
      expect(ActiveStorage::Blob.service).not_to receive(:upload)
      expect do
        Imap::ImapMailbox.new.process(inbound.mail, channel)
      end.not_to(change { [Attachment.count, ActiveStorage::Blob.count] })

      message = channel.inbox.messages.find_by!(source_id: inbound.mail.message_id)
      expect(message.attachments).to be_empty
      expect(message.content_attributes['rejected_attachments']).to eq([{ 'filename' => omitted_name, 'reason' => 'File type not supported' }])
    end
  end

  it 'keeps upstream body selection for an unnamed binary leaf that Mail does not attach' do
    source = source_with_part('Content-Type: application/octet-stream')
    inbound = ActionMailbox::InboundEmail.create_and_extract_message_id!(source)
    expect(inbound.mail.attachments).to be_empty
    inbound.raw_email.blob.open { |io| expect(io.read).to eq(source) }
    presenter = MailPresenter.new(inbound.mail)

    expect(ActiveStorage::Blob.service).not_to receive(:upload)
    expect(presenter.attachments).to be_empty
    expect(presenter.toybaco_rejected_attachments).to be_empty
    expect(presenter.text_content[:full]).to include('Keep this message')
  end

  it 'inspects a forbidden attachment nested inside an attached message' do
    inner = source_with_part('Content-Type: application/octet-stream; name=nested.exe')
    source = source_with_part('Content-Type: message/rfc822', inner, encoded: false, boundary: 'wrapper')
    mail = Mail.read_from_string(source)
    expect(mail.attachments.map(&:filename)).to eq(['nested.exe'])
    presenter = MailPresenter.new(mail)

    expect(ActiveStorage::Blob.service).not_to receive(:upload)
    expect(presenter.attachments).to be_empty
    expect(presenter.toybaco_rejected_attachments).to include(include('filename' => 'nested.exe'))
  end

  it 'inspects even candidates beyond the retained attachment limit without uploading rejected bytes' do
    mail = Mail.read_from_string(source_with_part('Content-Type: application/octet-stream; name=original.exe'))
    (Message::NUMBER_OF_PERMITTED_ATTACHMENTS + 1).times do |index|
      mail.attachments["allowed-#{index}.txt"] = { mime_type: 'text/plain', content: 'Allowed text' }
    end
    presenter = MailPresenter.new(mail)
    expect(ActiveStorage::Blob.service).to receive(:upload).exactly(Message::NUMBER_OF_PERMITTED_ATTACHMENTS).times.and_call_original
    expect(presenter.attachments.size).to eq(Message::NUMBER_OF_PERMITTED_ATTACHMENTS)
    expect(presenter.toybaco_rejected_attachments).to include(include('filename' => 'original.exe'))
  end
end
