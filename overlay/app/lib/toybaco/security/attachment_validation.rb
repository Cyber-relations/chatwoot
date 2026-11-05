# frozen_string_literal: true

module Toybaco::Security::AttachmentValidation
  def self.prepended(base)
    base.after_save :toybaco_record_late_attachment_omission
  end

  def file=(attachable)
    @toybaco_rejected_file = nil
    if attachable.blank?
      super
    else
      input = Toybaco::Security::AttachmentInput.new(attachable)
      super(input.checked)
    end
  rescue Toybaco::Security::AttachmentPolicy::Rejected => e
    # No ActiveStorage change is created, so neither validation nor commit can
    # upload rejected bytes. Defer the response until all message attributes exist.
    @toybaco_rejected_file = { filename: input.filename, reason: e.message }
  end

  def toybaco_attachment_omission
    return @toybaco_rejected_file.stringify_keys if @toybaco_rejected_file && toybaco_received_attachment?

    meta&.[]('rejected_attachment')
  end

  private

  def acceptable_file
    return toybaco_rejected_file if @toybaco_rejected_file
    return unless file.attached?

    validate_file_size(file.byte_size)
    errors.add(:file, 'type not supported') unless Toybaco::Security::AttachmentPolicy::ALLOWED_TYPES.include?(file.content_type)
    toybaco_detected_file_type
  end

  def toybaco_detected_file_type
    return unless %w[image audio video file].include?(file_type)

    media_type = file.content_type.to_s.split('/').first
    self.file_type = %w[image audio video].include?(media_type) ? media_type : 'file'
  end

  def toybaco_rejected_file
    if toybaco_received_attachment?
      self.file_type = :fallback
      self.external_url = nil
      self.fallback_title = "File not kept: #{@toybaco_rejected_file[:filename]} (#{@toybaco_rejected_file[:reason]})"
      self.meta = (meta || {}).merge('rejected_attachment' => @toybaco_rejected_file.stringify_keys)
    else
      errors.add(:file, @toybaco_rejected_file[:reason])
    end
  end

  def toybaco_received_attachment?
    return false unless message && !message.toybaco_interactive_upload
    return false if message.inbox.web_widget? || message.inbox.api?

    # Also covers Telegram/WhatsApp business echoes received from the provider.
    message.incoming? || message.sender_type != 'User'
  end

  # Messenger attaches files after the message and Attachment have been saved.
  # Other channels autosave their attachments with the message; do not recursively
  # save that parent or lose its original create/update callback changes.
  def toybaco_record_late_attachment_omission
    return unless toybaco_attachment_omission && message.persisted? && !message.toybaco_saving_attachments

    message.toybaco_record_attachment_omissions(self)
    message.save! if message.content_attributes_changed?
  end

  module MessageContext
    extend ActiveSupport::Concern

    attr_accessor :toybaco_interactive_upload
    attr_reader :toybaco_saving_attachments

    included do
      before_validation :toybaco_record_attachment_omissions
      around_save :toybaco_saving_attachment_omissions
    end

    def toybaco_record_attachment_omissions(extra = nil)
      if content_attributes&.[]('deleted')
        self.content_attributes = content_attributes.except('rejected_attachments')
        return
      end

      omissions = (attachments.to_a + [extra]).compact.filter_map(&:toybaco_attachment_omission)
      return if omissions.empty?

      attributes = content_attributes || {}
      self.content_attributes = attributes.merge('rejected_attachments' => (Array(attributes['rejected_attachments']) + omissions).uniq)
    end

    private

    def toybaco_saving_attachment_omissions
      @toybaco_saving_attachments = true
      yield
    ensure
      @toybaco_saving_attachments = false
    end
  end

  module MessageBuilder
    private

    def process_attachments
      @message.toybaco_interactive_upload = true
      super
    end
  end
end
