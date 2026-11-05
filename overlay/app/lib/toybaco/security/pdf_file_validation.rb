# frozen_string_literal: true

module Toybaco::Security::PdfFileValidation
  def self.prepended(base)
    base.validate :toybaco_pdf_file_rejection
  end

  def pdf_file=(attachable)
    @toybaco_rejected_pdf_file = nil
    if attachable.blank?
      super
    else
      super(Toybaco::Security::AttachmentInput.new(attachable, policy: Toybaco::Security::PdfDocumentPolicy).checked)
    end
  rescue Toybaco::Security::AttachmentPolicy::Rejected => e
    @toybaco_rejected_pdf_file = e.message
  end

  private

  def toybaco_pdf_file_rejection
    errors.add(:pdf_file, @toybaco_rejected_pdf_file) if @toybaco_rejected_pdf_file
  end
end
