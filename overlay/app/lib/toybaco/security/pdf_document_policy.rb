# frozen_string_literal: true

module Toybaco::Security::PdfDocumentPolicy
  def self.validate_size!(size)
    Toybaco::Security::AttachmentPolicy.validate_size!(size)
    raise Toybaco::Security::AttachmentPolicy::Rejected, 'File size is too big' if size > 10.megabytes
  end

  def self.identify!(io)
    validate_size!(io.size)
    type = Toybaco::Security::AttachmentPolicy.identify!(io)
    raise Toybaco::Security::AttachmentPolicy::Rejected, 'File must be PDF' unless type == 'application/pdf'

    type
  end
end
