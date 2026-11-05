# frozen_string_literal: true

require 'csv'

module Toybaco::Security::CsvImportPolicy
  def self.validate_size!(size)
    Toybaco::Security::AttachmentPolicy.validate_size!(size)
    raise Toybaco::Security::AttachmentPolicy::Rejected, 'File size is too big' if size > 10.megabytes
  end

  def self.identify!(io)
    validate_size!(io.size)
    type = Toybaco::Security::AttachmentPolicy.identify!(io)
    raise Toybaco::Security::AttachmentPolicy::Rejected, 'File must be CSV' unless %w[text/plain text/csv].include?(type)

    text = Toybaco::Security::AttachmentPolicy.decode_text(io.read).delete_prefix("\uFEFF")
    raise Toybaco::Security::AttachmentPolicy::Rejected, 'File must be CSV' if text.strip.empty?

    CSV.new(text).each { |_row| } # Parse the entire bounded input without accumulating rows.
    'text/csv'
  rescue CSV::MalformedCSVError
    raise Toybaco::Security::AttachmentPolicy::Rejected, 'File must be CSV'
  ensure
    io.rewind
  end
end
