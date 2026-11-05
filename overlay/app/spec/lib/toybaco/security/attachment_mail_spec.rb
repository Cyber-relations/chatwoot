# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Toybaco::Security::AttachmentMail do
  include_context 'without toybaco network connections'
  let(:account) { create(:account) }
  let(:channel) { create(:channel_email, account: account) }
  let(:html_file) { '<!doctype html><html><script>synthetic_rejected_payload()</script></html>' }

  # Deliberately raw MIME: Mail's builders normalize the structure that caused
  # the regression (inline body containers carrying Content-ID).
  def raw_body_source(body)
    <<~MAIL.gsub("\n", "\r\n")
      From: synthetic-sender@example.test
      To: #{channel.email}
      Subject: Body preservation
      Message-ID: <#{SecureRandom.uuid}@example.test>
      MIME-Version: 1.0
      Content-Type: multipart/mixed; boundary=outer

      --outer
      #{body.strip}
      --outer
      Content-Type: image/png; name=forbidden.png
      Content-Disposition: attachment; filename=forbidden.png
      Content-Transfer-Encoding: base64

      #{Base64.strict_encode64(html_file)}
      --outer--
    MAIL
  end

  def inline_body(type, content, cid: 'body')
    "Content-Type: #{type}\nContent-Disposition: inline\nContent-ID: <#{cid}>\n\n#{content}\n"
  end

  def alternative_body
    inline_body('multipart/alternative; boundary=alternative', <<~PARTS)
      --alternative
      #{inline_body('text/plain', 'Keep this message', cid: 'plain')}
      --alternative
      #{inline_body('text/html', '<p>Keep this message</p>', cid: 'html')}
      --alternative--
    PARTS
  end

  %w[html plain alternative related related_start].each do |shape|
    it "preserves raw #{shape} body parts and containers beside a forbidden real attachment" do
      body = case shape
             when 'html' then inline_body('text/html', '<p>Keep this message</p>')
             when 'plain' then inline_body('text/plain', 'Keep this message')
             when 'alternative' then alternative_body
             else
               image = inline_body('image/png; name=inline.png', Base64.strict_encode64(Rails.root.join('spec/assets/avatar.png').binread),
                                   cid: 'picture').sub('Content-Disposition: inline',
                                                       "Content-Transfer-Encoding: base64\nContent-Disposition: inline; filename=inline.png")
               root = inline_body('text/html', '<p>Keep this message</p><img src="cid:picture">')
               parts = shape == 'related_start' ? [image, root] : [root, image]
               inline_body('multipart/related; boundary=related; start="<body>"',
                           "#{parts.map { |part| "--related\n#{part}" }.join}--related--\n", cid: 'container')
             end
      source = raw_body_source(body)
      inbound = ActionMailbox::InboundEmail.create_and_extract_message_id!(source)
      inbound.raw_email.blob.open do |io|
        stored_source = io.read
        stored = Mail.read_from_string(stored_source)
        aggregate_failures do
          expect(stored_source).to eq(source)
          expect(stored.encoded).to include('Keep this message')
          expect(stored.parts.first.mime_type).to eq(body[/Content-Type: ([^;\n]+)/, 1])
          expect(stored.parts.first.content_id).to be_present
          expect(stored.attachments['forbidden.png'].body.decoded).to eq(html_file)
          if shape.start_with?('related')
            expect(stored.attachments['inline.png'].body.decoded).to eq(Rails.root.join('spec/assets/avatar.png').binread)
          end
        end
      end

      Imap::ImapMailbox.new.process(inbound.mail, channel)
      message = channel.inbox.messages.find_by!(source_id: inbound.mail.message_id)
      expect(message.content).to include('Keep this message')
      expect(message.content_attributes['rejected_attachments']).to eq([{ 'filename' => 'forbidden.png', 'reason' => 'File type not supported' }])
      expect(ActiveStorage::Blob.where(filename: 'forbidden.png')).not_to exist
      expect(message.content_attributes.dig('email', 'html_content', 'full')).to include('Keep this message') unless shape == 'plain'
      expect(message.content_attributes.dig('email', 'text_content', 'full')).to include('Keep this message') if %w[plain alternative].include?(shape)
    end
  end

  def received_mail
    Mail.new.tap do |mail|
      mail.from = 'synthetic-sender@example.test'
      mail.to = channel.email
      mail.subject = 'Synthetic attachments'
      mail.message_id = "#{SecureRandom.uuid}@example.test"
      mail.text_part = Mail::Part.new(body: 'Keep this message')
      mail.attachments['forged.png'] = { mime_type: 'image/png', content: html_file }
      mail.attachments['allowed.txt'] = { mime_type: 'application/octet-stream', content: 'Allowed plain text' }
    end
  end

  { 'voice-opus.ogg' => 'audio/opus', 'voice-vorbis.ogg' => 'audio/ogg' }.each do |fixture, detected_type|
    it "keeps real #{fixture} voice bytes through incoming email source and IMAP ingestion" do
      bytes = Rails.root.join('spec/assets/toybaco/attachment_formats', fixture).binread
      expect(Marcel::MimeType.for(StringIO.new(bytes))).to eq(detected_type)
      mail = received_mail
      mail.attachments[fixture] = { mime_type: 'audio/ogg', content: bytes }
      inbound = ActionMailbox::InboundEmail.create_and_extract_message_id!(mail.encoded)
      Imap::ImapMailbox.new.process(inbound.mail, channel)

      message = channel.inbox.messages.find_by!(content: 'Keep this message')
      attachment = message.attachments.find { |item| item.file.filename.to_s == fixture }
      expect(attachment).to be_present
      expect(attachment).to be_audio
      expect(attachment.file.content_type).to eq(detected_type)
      attachment.file.open { |io| expect(io.read).to eq(bytes) }
      expect(message.content_attributes['rejected_attachments'].pluck('filename')).to eq(['forged.png'])
    end
  end

  it 'checks the decoded mail part before MailPresenter can create_and_upload a blob' do
    presenter = MailPresenter.new(received_mail, account)
    parts = nil
    expect { parts = presenter.attachments }.to change(ActiveStorage::Blob, :count).by(1)

    expect(presenter.toybaco_rejected_attachments).to include(include('filename' => 'forged.png'))
    expect(parts.last[:blob].content_type).to eq('text/plain')
    expect(ActiveStorage::Blob.where(filename: 'forged.png')).not_to exist
    expect { presenter.attachments }.not_to change(ActiveStorage::Blob, :count)
  end

  it 'keeps IMAP message text, the allowed file and the omitted filename' do
    Imap::ImapMailbox.new.process(received_mail, channel)
    message = channel.inbox.messages.find_by!(content: 'Keep this message')

    expect(message.attachments.select { |item| item.file.attached? }.map { |item| item.file.filename.to_s }).to eq(['allowed.txt'])
    expect(message.content_attributes['rejected_attachments']).to include(include('filename' => 'forged.png'))
    expect(ActiveStorage::Blob.where(filename: 'forged.png')).not_to exist
  end

  it 'removes a forbidden inline CID image before either inline embedding or regular attachment storage' do
    mail = received_mail
    mail.html_part = Mail::Part.new(content_type: 'text/html', body: '<p>Keep this message</p><img src="cid:synthetic-image">')
    part = mail.attachments['forged.png']
    part.content_disposition = 'inline; filename="forged.png"'
    part.content_id = '<synthetic-image>'
    Imap::ImapMailbox.new.process(mail, channel)
    message = channel.inbox.messages.find_by!(content: 'Keep this message')

    expect(ActiveStorage::Blob.where(filename: 'forged.png')).not_to exist
    expect(message.content_attributes['rejected_attachments']).to include(include('filename' => 'forged.png'))
    expect(message.content_attributes['email']['html_content']['full']).not_to include('/rails/active_storage/')
  end

  it 'retains the exact RFC822 source while rejecting a forbidden conversation attachment' do
    source = received_mail.encoded
    inbound = ActionMailbox::InboundEmail.create_and_extract_message_id!(source)
    inbound.raw_email.blob.open { |io| expect(io.read).to eq(source) }
    Imap::ImapMailbox.new.process(inbound.mail, channel)
    message = channel.inbox.messages.find_by!(content: 'Keep this message')
    expect(message.content_attributes['rejected_attachments']).to include(include('filename' => 'forged.png'))
  end

  [true, false].each do |with_headers|
    it "creates one inbound record and conversation across duplicate deliveries with headers=#{with_headers}" do
      source = received_mail.encoded
      source = source.gsub(/^(?:Message-ID|Date):[^\r\n]*\r?\n/i, '') unless with_headers
      expect do
        2.times do
          inbound = ActionMailbox::InboundEmail.create_and_extract_message_id!(source)
          inbound&.route
        end
      end.to change(ActionMailbox::InboundEmail, :count).by(1).and change(Conversation, :count).by(1)

      inbound = ActionMailbox::InboundEmail.find_by!(message_checksum: OpenSSL::Digest::SHA1.hexdigest(source))
      expect(inbound).to be_delivered
      inbound.raw_email.blob.open { |io| expect(io.read).to eq(source) }
      expect(channel.inbox.messages.count).to eq(1)
    end
  end

  def single_part_source(body)
    "From: synthetic@example.test\r\nTo: #{channel.email}\r\n" \
      "Content-Type: text/html\r\nContent-Disposition: attachment; filename=bad.html\r\n\r\n#{body}"
  end

  it 'leaves upstream single-part body and attachment selection unchanged' do
    # Upstream omits html_content when HtmlParser finds no visible reply text.
    body = '<!doctype html><html><body><p>Keep this message</p><script>synthetic_rejected_payload()</script></body></html>'
    source = single_part_source(body)
    inbound = ActionMailbox::InboundEmail.create_and_extract_message_id!(source)
    inbound.raw_email.blob.open { |io| expect(io.read).to eq(source) }
    expect(inbound.mail.attachments).to be_empty
    presenter = MailPresenter.new(inbound.mail)
    expect(presenter.html_content[:full]).to eq(body)
    expect(presenter.html_content[:reply]).to include('Keep this message')
    expect(presenter.attachments).to be_empty
    expect(presenter.toybaco_rejected_attachments).to be_empty
  end

  it 'retains a script-only single-part source while preserving upstream empty reply handling' do
    source = single_part_source(html_file)
    inbound = ActionMailbox::InboundEmail.create_and_extract_message_id!(source)
    inbound.raw_email.blob.open { |io| expect(io.read).to eq(source) }
    expect(inbound.mail.attachments).to be_empty
    presenter = MailPresenter.new(inbound.mail)

    expect(presenter.mail_content(nil)).to eq(html_file)
    expect(presenter.html_content).to be_empty
    expect(presenter.attachments).to be_empty
    expect(presenter.toybaco_rejected_attachments).to be_empty
  end

  it 'retains the original raw source when every attachment is rejected' do
    mail = Mail.new(from: 'synthetic@example.test', to: channel.email, subject: 'Attachments only')
    mail.attachments['bad.html'] = { mime_type: 'text/html', content: html_file }
    source = mail.encoded
    inbound = ActionMailbox::InboundEmail.create_and_extract_message_id!(source)
    inbound.raw_email.blob.open { |io| expect(io.read).to eq(source) }
    presenter = MailPresenter.new(inbound.mail)
    expect(presenter.attachments).to be_empty
    expect(presenter.toybaco_rejected_attachments).to include(include('filename' => 'bad.html'))
  end

  it 'records all rejected names without using up the permitted attachment count or storing unused files' do
    mail = received_mail
    16.times { |index| mail.attachments["blocked-#{index}.html"] = { mime_type: 'image/png', content: html_file } }
    Imap::ImapMailbox.new.process(mail, channel)
    message = channel.inbox.messages.find_by!(content: 'Keep this message')

    expect(message.content_attributes['rejected_attachments'].size).to eq(17)
    expect(message.attachments.size).to eq(1)
    expect(message.attachments.first.file.filename.to_s).to eq('allowed.txt')
  end

  it 'does not accept a sender-supplied omission header as trusted ingress metadata' do
    mail = received_mail
    mail['X-Toybaco-Rejected-Attachments'] = Base64.strict_encode64([{ filename: 'forged-name.exe', reason: 'forged reason' }].to_json)
    inbound = ActionMailbox::InboundEmail.create_and_extract_message_id!(mail.encoded)
    Imap::ImapMailbox.new.process(inbound.mail, channel)

    names = channel.inbox.messages.find_by!(content: 'Keep this message').content_attributes['rejected_attachments'].pluck('filename')
    expect(names).to eq(['forged.png'])
  end
end
