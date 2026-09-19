# frozen_string_literal: true

require 'base64'
require 'mail'
require_relative 'microsoft_api'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    class MicrosoftAttachments
      MAX_COUNT = 1000
      MAX_TOTAL_BYTES = 25_000_000
      attr_reader :omissions

      def initialize(api:, access_token:, message_id:, limit:, count:)
        @api = api
        @token = access_token
        @message_id = message_id
        @limit = [limit, MicrosoftApi::MAX_ATTACHMENT_BYTES].min
        @count = [count, 15].min
        @accepted = 0
        @bytes = 0
        @seen = {}
        @omissions = []
      end

      def append_to(mail)
        cursor = nil
        cursors = {}
        loop do
          page = @api.attachments(access_token: @token, id: @message_id, cursor: cursor)
          files = page.fetch('value')
          raise MicrosoftApi::Error, 502 unless files.is_a?(Array) && files.length <= MAX_COUNT

          files.each { |file| append(mail, file) }
          cursor = page['@odata.nextLink']
          break unless cursor
          raise MicrosoftApi::Error, 502 if cursors[cursor] || cursors.length >= 50

          cursors[cursor] = true
        end
      end

      private

      def append(mail, file)
        validate_file!(file)
        return if @seen[file.fetch('id')]

        @seen[file.fetch('id')] = true
        raise MicrosoftApi::Error, 502 if @seen.length > MAX_COUNT

        reason = exclusion(file)
        return omit(file, reason) if reason

        download_to(mail, file)
      end

      def download_to(mail, file)
        bytes, cid = contents(file)
        return omit(file, 'file_too_large') if bytes.bytesize > @limit || @bytes + bytes.bytesize > MAX_TOTAL_BYTES

        mail.add_part(part(file, bytes, cid))
        @accepted += 1
        @bytes += bytes.bytesize
      rescue MicrosoftApi::Error => e
        raise unless [404, 405, 413].include?(e.status)

        omit(file, e.status == 413 ? 'file_too_large' : 'not_available')
      end

      def validate_file!(file)
        valid = file.is_a?(Hash) && file['id'].is_a?(String) && file['size'].is_a?(Integer) && file['size'] >= 0
        raise MicrosoftApi::Error, 502 unless valid
      end

      def exclusion(file)
        return 'not_available' unless %w[microsoft.graph.fileAttachment
                                         microsoft.graph.itemAttachment].include?(file['@odata.type'].to_s.delete_prefix('#'))
        return 'file_too_large' if file['size'] > @limit || @bytes + file['size'] > MAX_TOTAL_BYTES

        'attachment_count' if @accepted >= @count
      end

      def contents(file)
        return inline_contents(file) if file['isInline'] == true

        response = @api.attachment(access_token: @token, message_id: @message_id, id: file.fetch('id'))
        [response.fetch(:body), nil]
      end

      def inline_contents(file)
        data = @api.attachment_details(access_token: @token, message_id: @message_id, id: file.fetch('id'))
        raise MicrosoftApi::Error, 502 unless data['id'] == file['id'] && data['contentBytes'].is_a?(String)

        bytes = Base64.strict_decode64(data.fetch('contentBytes'))
        cid = data['contentId'].to_s
        raise MicrosoftApi::Error, 502 if cid.match?(/[\r\n\u0000]/) || cid.bytesize > 998

        [bytes, cid]
      rescue ArgumentError
        raise MicrosoftApi::Error.new(502), cause: nil
      end

      def part(file, bytes, cid)
        item = Mail::Part.new
        mime = file['contentType'].to_s
        item.content_type = mime.match?(%r{\A[a-zA-Z0-9.+_-]+/[a-zA-Z0-9.+_-]+\z}) ? mime : 'application/octet-stream'
        name = Mail::Encodings.decode_encode(filename(file), :encode).gsub(/["\\]/) { |char| "\\#{char}" }
        disposition = cid.to_s.empty? ? 'attachment' : 'inline'
        item.content_disposition = "#{disposition}; filename=\"#{name}\""
        item.content_id = cid unless cid.to_s.empty?
        item.content_transfer_encoding = 'base64'
        item.body = Base64.strict_encode64(bytes)
        item
      end

      def filename(file)
        name = file['name'].to_s.delete("\r\n\u0000").slice(0, 200)
        name.empty? ? '添付ファイル' : name
      end

      def omit(file, reason)
        @omissions << { 'name' => filename(file), 'reason' => reason, 'size' => file['size'] }
        nil
      end
    end
  end
end
