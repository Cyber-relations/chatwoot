# frozen_string_literal: true

module Toybaco::Security::AttachmentUploads
  PURPOSE = :toybaco_attachment_upload
  PENDING_KEY = 'toybaco_attachment_upload_pending'

  module DisableStockDirectUpload
    def create
      # The account/widget subclasses keep their authenticated reservation
      # protocol. The Rails route itself must never mint a storage capability.
      return head :not_found if instance_of?(ActiveStorage::DirectUploadsController)

      super
    end
  end

  module AccountUpload
    private

    def create_and_save_blob(io, filename, _content_type)
      type = Toybaco::Security::AttachmentPolicy.identify!(io)
      ActiveStorage::Blob.create_and_upload!(io: io, filename: filename, content_type: type, identify: false)
    rescue Toybaco::Security::AttachmentPolicy::Rejected => e
      render_error(e.message, :unprocessable_entity)
    end
  end

  # Preserve ActiveStorage's POST -> PUT -> signed_id protocol. The PUT goes
  # through our validator instead of granting a write to permanent storage.
  module DirectUpload
    def create
      Toybaco::Security::AttachmentPolicy.validate_size!(Integer(params.require(:blob).fetch(:byte_size)))
      super
    rescue Toybaco::Security::AttachmentPolicy::Rejected, ArgumentError, TypeError
      render json: { error: 'File size is invalid or too big' }, status: :unprocessable_entity
    end

    private

    def blob_args
      super.merge(metadata: { PENDING_KEY => true })
    end

    def direct_upload_json(blob)
      token = blob.signed_id(purpose: PURPOSE, expires_in: ActiveStorage.service_urls_expire_in)
      upload_url = Rails.application.routes.url_helpers.toybaco_attachment_upload_url(
        upload_token: token, host: request.host_with_port, protocol: request.protocol
      )
      blob.as_json(root: false, methods: :signed_id).merge(
        direct_upload: {
          url: upload_url,
          headers: { 'Content-Type' => 'application/octet-stream' }
        }
      )
    end
  end
end
