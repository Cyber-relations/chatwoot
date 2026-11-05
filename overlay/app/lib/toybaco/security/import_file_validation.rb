# frozen_string_literal: true

module Toybaco::Security::ImportFileValidation
  def self.prepended(base)
    base.validate :toybaco_import_file_rejection
  end

  def import_file=(attachable)
    @toybaco_rejected_import_file = nil
    if attachable.blank?
      super
    else
      super(Toybaco::Security::AttachmentInput.new(attachable, policy: Toybaco::Security::CsvImportPolicy).checked)
    end
  rescue Toybaco::Security::AttachmentPolicy::Rejected => e
    @toybaco_rejected_import_file = e.message
  end

  private

  def toybaco_import_file_rejection
    errors.add(:import_file, @toybaco_rejected_import_file) if @toybaco_rejected_import_file
  end
end
