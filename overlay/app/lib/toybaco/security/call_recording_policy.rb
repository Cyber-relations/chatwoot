# frozen_string_literal: true

module Toybaco::Security::CallRecordingPolicy
  def self.validate_size!(size)
    Toybaco::Security::AttachmentPolicy.validate_size!(size)
  end

  def self.identify!(io)
    type = Toybaco::Security::AttachmentPolicy.identify!(io)
    raise Toybaco::Security::AttachmentPolicy::Rejected, 'File must be audio' unless type.start_with?('audio/')

    type
  end
end
