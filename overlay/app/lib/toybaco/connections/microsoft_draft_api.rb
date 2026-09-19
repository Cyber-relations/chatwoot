# frozen_string_literal: true

require 'base64'
require_relative 'microsoft_api'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    # The caller persists the immutable draft ID before any send attempt. These
    # requests never retry mutations; a timeout is an unknown outcome.
    class MicrosoftDraftApi < MicrosoftApi
      SMALL_ATTACHMENT_LIMIT = 3_000_000
      UPLOAD_CHUNK_LIMIT = 4_000_000

      def create_draft(access_token:, message:)
        data = request(:post, "#{API_URL}/messages", access_token, message)
        raise Error, 502 unless data['isDraft'] == true && data['id'].is_a?(String)

        segment(data.fetch('id'))
        data
      end

      def create_reply(access_token:, message_id:, message:)
        data = request(:post, API_URL + "/messages/#{segment(message_id)}/createReply", access_token, 'message' => message)
        raise Error, 502 unless data['isDraft'] == true && data['id'].is_a?(String)

        segment(data.fetch('id'))
        data
      end

      def add_attachment(access_token:, draft_id:, file:, bytes:)
        raise ArgumentError, 'attachment requires an upload session' if bytes.bytesize >= SMALL_ATTACHMENT_LIMIT

        item = { '@odata.type' => '#microsoft.graph.fileAttachment', 'name' => file.fetch(:name), 'contentType' => file.fetch(:content_type),
                 'contentBytes' => Base64.strict_encode64(bytes) }
        item.merge!(inline_fields(file[:inline], file[:content_id]))
        request(:post, API_URL + "/messages/#{segment(draft_id)}/attachments", access_token, item)
      end

      def upload_session(access_token:, draft_id:, file:, size:)
        raise ArgumentError, 'invalid attachment size' unless size.is_a?(Integer) && (SMALL_ATTACHMENT_LIMIT..MAX_ATTACHMENT_BYTES).cover?(size)

        item = { 'attachmentType' => 'file', 'name' => file.fetch(:name), 'contentType' => file.fetch(:content_type), 'size' => size }
        item.merge!(inline_fields(file[:inline], file[:content_id]))
        request(:post, API_URL + "/messages/#{segment(draft_id)}/attachments/createUploadSession", access_token, 'AttachmentItem' => item)
      end

      def upload_chunk(url:, bytes:, offset:, total:)
        MicrosoftTransport.validate_upload_url!(url)
        validate_range!(bytes, offset, total)
        headers = { 'Content-Type' => 'application/octet-stream', 'Content-Length' => bytes.bytesize.to_s,
                    'Content-Range' => "bytes #{offset}-#{offset + bytes.bytesize - 1}/#{total}" }
        # The opaque URL carries its own upload authorization. Never attach the
        # mailbox access token, including when the provider returns an error.
        response = @transport.call(method: :put, url: url, headers: headers, body: bytes)
        raise Error.new(response[:status], response[:retry_after]) unless [200, 201].include?(response[:status])

        { status: response[:status], data: upload_data(response[:body]) }
      end

      def send_draft(access_token:, draft_id:)
        response = raw_request(:post, API_URL + "/messages/#{segment(draft_id)}/send", access_token, body: '')
        raise Error, 502 unless response[:status] == 202 && response[:body].empty?

        { accepted: true, request_id: response[:request_id] }
      end

      private

      def inline_fields(inline, cid)
        return {} unless inline
        raise ArgumentError, 'invalid inline content ID' if cid.to_s.empty? || cid.bytesize > 998 || cid.match?(/[\r\n\u0000]/)

        { 'isInline' => true, 'contentId' => cid }
      end

      def validate_range!(bytes, offset, total)
        raise ArgumentError, 'invalid upload range' unless range_types?(bytes, offset, total)

        valid = (1...UPLOAD_CHUNK_LIMIT).cover?(bytes.bytesize) && offset >= 0 &&
                total <= MAX_ATTACHMENT_BYTES && offset + bytes.bytesize <= total
        raise ArgumentError, 'invalid upload range' unless valid
      end

      def range_types?(bytes, offset, total)
        bytes.is_a?(String) && offset.is_a?(Integer) && total.is_a?(Integer)
      end

      def upload_data(body)
        result = body.to_s.empty? ? {} : JSON.parse(body, allow_duplicate_key: false)
        raise Error, 502 unless result.is_a?(Hash)

        result
      rescue JSON::ParserError
        raise Error.new(502), cause: nil
      end
    end
  end
end
