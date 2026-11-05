# frozen_string_literal: true

class Toybaco::AttachmentUploadsController < ActiveStorage::BaseController
  skip_before_action :verify_authenticity_token

  # The expiring, purpose-bound token grants one upload to one reserved blob,
  # just as the old presigned PUT did. NOWAIT rejects overlapping replays without
  # tying up another request thread/connection while the first upload stores.
  def update
    blob = ActiveStorage::Blob.find_signed!(params[:upload_token], purpose: Toybaco::Security::AttachmentUploads::PURPOSE)
    blob.with_lock('FOR UPDATE NOWAIT') do
      raise Toybaco::Security::AttachmentPolicy::Rejected, 'File upload already completed' unless
        blob.metadata[Toybaco::Security::AttachmentUploads::PENDING_KEY] == true

      upload_checked_body(blob)
    end
    head :no_content
  rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
    head :not_found
  rescue ActiveRecord::LockWaitTimeout
    response.set_header('Retry-After', '1')
    head :conflict
  rescue Toybaco::Security::AttachmentPolicy::Rejected, ActiveStorage::IntegrityError => e
    message = e.is_a?(ActiveStorage::IntegrityError) ? 'File checksum does not match' : e.message
    render json: { error: message }, status: :unprocessable_entity
  end

  private

  def upload_checked_body(blob)
    Toybaco::Security::AttachmentPolicy.validate_size!(blob.byte_size)
    Tempfile.create('toybaco-attachment', binmode: true) do |io|
      # Bound actual bytes too; Content-Length and the reservation are untrusted.
      IO.copy_stream(request.body, io, blob.byte_size + 1)
      blob.content_type = checked_content_type(blob, io)
      blob.metadata = { 'identified' => true }
      blob.save!
      blob.upload_without_unfurling(io)
    end
  end

  def checked_content_type(blob, io)
    raise Toybaco::Security::AttachmentPolicy::Rejected, 'File size does not match' unless io.size == blob.byte_size

    type = Toybaco::Security::AttachmentPolicy.identify!(io)
    raise ActiveStorage::IntegrityError unless Digest::MD5.file(io.path).base64digest == blob.checksum

    type
  end
end
