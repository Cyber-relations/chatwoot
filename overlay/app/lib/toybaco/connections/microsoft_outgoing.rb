# frozen_string_literal: true

require_relative 'microsoft_draft_api'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    class MicrosoftOutgoing
      CHUNK_BYTES = 3_932_160

      def initialize(mail, api:, access_token:)
        @mail = mail
        @api = api
        @token = access_token
      end

      def message
        part = @mail.html_part || @mail.text_part || @mail
        { 'subject' => @mail.subject.to_s.delete("\r\n\u0000"),
          'body' => { 'contentType' => part.mime_type == 'text/html' ? 'HTML' : 'Text', 'content' => part.decoded },
          'toRecipients' => recipients(@mail.to), 'ccRecipients' => recipients(@mail.cc), 'bccRecipients' => recipients(@mail.bcc),
          'replyTo' => recipients(@mail.reply_to) }
      end

      def attach(draft_id)
        raise MicrosoftApi::Error, 413 if @mail.attachments.length > 15

        total = 0
        @mail.attachments.each do |part|
          bytes = part.decoded
          total += bytes.bytesize
          raise MicrosoftApi::Error, 413 if total > MicrosoftApi::MAX_ATTACHMENT_BYTES

          upload(draft_id, part, bytes)
        end
      end

      private

      def recipients(values)
        rows = Array(values)
        raise ArgumentError, 'too many recipients' if rows.length > 100

        rows.map do |email|
          raise ArgumentError, 'invalid recipient' unless email.to_s.match?(URI::MailTo::EMAIL_REGEXP) && !email.match?(/[\r\n]/)

          { 'emailAddress' => { 'address' => email } }
        end
      end

      def upload(draft_id, part, bytes)
        file = { name: part.filename.to_s.delete("\r\n\u0000").slice(0, 200), content_type: part.mime_type || 'application/octet-stream',
                 inline: part.inline?, content_id: part.content_id.to_s.delete_prefix('<').delete_suffix('>') }
        args = { access_token: @token, draft_id: draft_id, file: file }
        return @api.add_attachment(**args, bytes: bytes) if bytes.bytesize < MicrosoftDraftApi::SMALL_ATTACHMENT_LIMIT

        session = @api.upload_session(**args, size: bytes.bytesize)
        offset = 0
        while offset < bytes.bytesize
          chunk = bytes.byteslice(offset, CHUNK_BYTES)
          result = @api.upload_chunk(url: session.fetch('uploadUrl'), bytes: chunk, offset: offset, total: bytes.bytesize)
          offset += chunk.bytesize
          validate_acknowledgement!(result, offset, bytes.bytesize)
        end
      end

      def validate_acknowledgement!(result, offset, total)
        return if offset == total && result[:status] == 201
        return if offset < total && result[:status] == 200 && result.dig(:data, 'nextExpectedRanges') == ["#{offset}-"]

        raise MicrosoftApi::Error, 502
      end
    end
  end
end
