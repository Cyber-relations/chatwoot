# frozen_string_literal: true

# Normalize the same attachables accepted by has_one_attached. Inspection of an
# existing blob always opens its bytes, ignoring even identified/analyzed metadata.
class Toybaco::Security::AttachmentInput
  attr_reader :filename

  def initialize(attachable, policy: Toybaco::Security::AttachmentPolicy)
    @policy = policy
    @attachable = attachable.is_a?(String) ? ActiveStorage::Blob.find_signed!(attachable) : attachable
    @filename = input_filename.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace).delete("\u0000")
  end

  def checked
    return checked_blob if @attachable.is_a?(ActiveStorage::Blob)

    io = input_io
    type = @policy.identify!(io)
    { io: io, filename: filename, content_type: type, identify: false }
  end

  private

  def checked_blob
    @policy.validate_size!(@attachable.byte_size)
    @attachable.open do |io|
      type = @policy.identify!(io)
      @attachable.update!(content_type: type, metadata: @attachable.metadata.merge('identified' => true))
    end
    @attachable
  rescue ActiveStorage::FileNotFoundError, ActiveStorage::IntegrityError
    raise Toybaco::Security::AttachmentPolicy::Rejected, 'File upload is incomplete'
  end

  def input_filename
    return @attachable[:filename] if @attachable.is_a?(Hash)
    return @attachable.filename if @attachable.is_a?(ActiveStorage::Blob)
    return @attachable.original_filename if @attachable.respond_to?(:original_filename)

    File.basename(@attachable.path)
  end

  def input_io
    return @attachable.fetch(:io) if @attachable.is_a?(Hash)
    return @attachable.tempfile if @attachable.respond_to?(:tempfile)
    return @attachable.open if @attachable.is_a?(Pathname)

    @attachable
  end
end
