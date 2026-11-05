# frozen_string_literal: true

module Toybaco::Security::AvatarPolicy
  def self.validate_size!(size)
    raise Toybaco::Security::AttachmentPolicy::Rejected, 'File size is too big' if size > 15.megabytes
    raise Toybaco::Security::AttachmentPolicy::Rejected, 'File size is invalid' if size.negative?
  end

  def self.identify!(io)
    validate_size!(io.size)
    io.rewind
    type = Marcel::MimeType.for(io).downcase
    raise Toybaco::Security::AttachmentPolicy::Rejected, 'File type not supported' unless Avatarable::ALLOWED_AVATAR_CONTENT_TYPES.include?(type)

    type
  ensure
    io.rewind
  end
end
