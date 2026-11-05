# frozen_string_literal: true

module Toybaco::Security::AttachmentSms
  private

  # Upstream silently skips .smil/.xml by URL suffix. Send all downloaded bytes
  # through the shared policy so omitted files retain their original names too.
  def attach_files
    Array(params[:media]).each do |media_url|
      download_media(media_url) do |io, filename, content_type|
        @message.attachments.new(
          account_id: @message.account_id, file_type: file_type(content_type),
          file: { io: io, filename: filename, content_type: content_type }
        )
      end
    end
  end
end
