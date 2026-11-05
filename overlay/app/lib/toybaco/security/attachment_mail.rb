# frozen_string_literal: true

module Toybaco::Security::AttachmentMail
  def self.inspect_part(part)
    raise Toybaco::Security::AttachmentPolicy::Rejected, 'File type not supported' if part.multipart?

    io = StringIO.new(part.body.decoded)
    type = Toybaco::Security::AttachmentPolicy.identify!(io)
    { io: io, filename: part.filename.presence || "attachment_#{SecureRandom.hex(4)}", content_type: type, identify: false }
  end

  def self.omission(part, error)
    filename = (part.filename.presence || 'attachment').encode(Encoding::UTF_8, invalid: :replace, undef: :replace).delete("\u0000")
    { 'filename' => filename, 'reason' => error.message }
  end

  def self.related_root?(mail, part)
    return false unless mail.multipart?

    return true if mail.mime_type == 'multipart/related' && related_body_part(mail).equal?(part)

    mail.parts.any? { |child| related_root?(child, part) }
  end

  def self.related_body_part(mail)
    start = mail.content_type_parameters['start'].to_s.delete('<>')
    mail.parts.find { |part| start.present? && part.content_id.to_s.delete('<>') == start } || mail.parts.first
  end

  private_class_method :related_body_part

  module Presenter
    def attachments
      return @toybaco_attachments if @toybaco_attachments

      @toybaco_rejected_attachments = []
      # Match upstream's candidates, including nested messages, Content-Location
      # attachments and blank filenames. Never reclassify or rewrite body parts.
      inputs = mail.attachments.filter_map { |part| toybaco_mail_input(part) }
      @toybaco_attachments = inputs.last(Message::NUMBER_OF_PERMITTED_ATTACHMENTS).map do |part, input|
        { original: part, blob: ActiveStorage::Blob.create_and_upload!(**input),
          related_root: Toybaco::Security::AttachmentMail.related_root?(mail, part) }
      end
    end

    def toybaco_rejected_attachments
      attachments
      @toybaco_rejected_attachments
    end

    private

    def toybaco_mail_input(part)
      [part, Toybaco::Security::AttachmentMail.inspect_part(part)]
    rescue Toybaco::Security::AttachmentPolicy::Rejected => e
      @toybaco_rejected_attachments << Toybaco::Security::AttachmentMail.omission(part, e)
      nil
    end
  end

  module Mailbox
    private

    def add_attachments_to_message
      return super if @message.blank?

      omissions = processed_mail.toybaco_rejected_attachments
      @message.content_attributes = @message.content_attributes.merge('rejected_attachments' => omissions) if omissions.any?
      super
    end

    def inline_attachment?(attachment)
      return false if attachment[:related_root]

      attachment.fetch(:blob).content_type.start_with?('image/') && super
    end
  end
end
