# frozen_string_literal: true

require 'base64'
require 'mail'
require_relative 'gmail_api'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    # Read the MIME tree before downloading individual attachments. A large
    # attachment never requires downloading the entire encoded RFC message.
    class GmailParts
      MAX_ATTACHMENT_BYTES = 25_000_000
      MAX_PARTS = 1000
      HEADERS = %w[from to cc bcc reply-to subject date message-id in-reply-to references
                   content-type content-disposition content-id mime-version auto-submitted x-autoreply
                   x-original-from x-original-sender x-forwarded-for x-failed-recipients].freeze
      attr_reader :omissions

      def initialize(api:, access_token:, data:, attachment_limit: MAX_ATTACHMENT_BYTES, attachment_count: 15)
        @api = api
        @token = access_token
        @data = data
        @limit = [attachment_limit, MAX_ATTACHMENT_BYTES].min
        @attachment_count = attachment_count
        @visited = 0
        @accepted = 0
        @omissions = []
      end

      def mail
        result = build(@data.fetch('payload'), root: true, depth: 0)
        unless result
          result = Mail.new
          headers(result, @data.fetch('payload'))
          result.content_disposition = nil
          result.content_type = 'text/plain'
          result.body = ''
        end
        result.message_id ||= message_id
        result
      end

      def message_id
        @message_id ||= begin
          header = Mail.new
          headers(header, @data.fetch('payload'))
          header.message_id || "gmail-#{@data.fetch('id')}@toybaco.invalid"
        end
      end

      private

      def build(part, depth:, root: false)
        validate_part!(part, depth)
        reason = omission_reason(part)
        return omit(part, reason) if reason

        item = root ? Mail.new : Mail::Part.new
        headers(item, part)
        children = part.fetch('parts', [])
        raise GmailApi::Error, 502 unless children.is_a?(Array)

        return unless populate(item, part, children, depth)

        item
      end

      def validate_part!(part, depth)
        @visited += 1
        raise GmailApi::Error, 502 unless part.is_a?(Hash) && depth <= 50 && @visited <= MAX_PARTS
      end

      def omission_reason(part)
        return unless attachment?(part)
        return 'file_too_large' if declared_size(part) > @limit

        'attachment_count' if @accepted >= @attachment_count
      end

      def populate(item, part, children, depth)
        return fill_body(item, part) unless children.any? && !attachment?(part)

        children.each do |child|
          built = build(child, depth: depth + 1)
          item.add_part(built) if built
        end
        true
      end

      def headers(item, part)
        item.content_type = part['mimeType'].to_s.empty? ? 'text/plain' : part['mimeType']
        Array(part['headers']).each do |header|
          name, value = header.values_at('name', 'value')
          next unless allowed_header?(name, value)

          # Unfold RFC continuation lines, but never turn a value into an
          # additional header. Content transfer encoding is set after decode.
          item[name] = value.gsub(/\r?\n[ \t]+/, ' ').delete("\r\n\u0000")
        end
        attachment_headers(item, part)
      end

      def allowed_header?(name, value)
        name.is_a?(String) && HEADERS.include?(name.downcase) && value.is_a?(String)
      end

      def attachment_headers(item, part)
        return unless attachment?(part)

        item.content_disposition ||= 'attachment'
        return if item.filename

        name = Mail::Encodings.decode_encode(safe_filename(part), :encode).gsub(/["\\]/) { |char| "\\#{char}" }
        item.content_disposition = "#{item.content_disposition}; filename=\"#{name}\""
      end

      def attachment?(part)
        return true unless part['filename'].to_s.empty?

        mime = part['mimeType'].to_s.downcase
        return true unless mime.empty? || %w[text/plain text/html].include?(mime) || mime.start_with?('multipart/')

        Array(part['headers']).any? do |header|
          header['name'].to_s.downcase == 'content-disposition' && header['value'].to_s.match?(/\A\s*attachment\b/i)
        end
      end

      def declared_size(part)
        size = part.dig('body', 'size')
        raise GmailApi::Error, 502 unless size.is_a?(Integer) && size >= 0

        size
      end

      def fill_body(item, part)
        decoded = decode(part_body(part))
        return omit(part, 'file_too_large') if attachment?(part) && decoded.bytesize > @limit

        item.content_transfer_encoding = 'base64'
        item.body = Base64.strict_encode64(decoded)
        @accepted += 1 if attachment?(part)
        true
      rescue GmailApi::Error => e
        raise unless skippable_attachment_error?(part, e)

        omit(part, e.status == 413 ? 'file_too_large' : 'not_available')
      end

      def skippable_attachment_error?(part, error)
        attachment?(part) && [404, 413].include?(error.status)
      end

      def part_body(part)
        body = part.fetch('body', {})
        return body unless body['attachmentId']

        @api.attachment(access_token: @token, message_id: @data.fetch('id'), id: body['attachmentId'])
      end

      def decode(body)
        data = body.fetch('data', '')
        size = body['size']
        valid = size.is_a?(Integer) && size >= 0 && data.is_a?(String) && data.match?(/\A[A-Za-z0-9_-]*={0,2}\z/)
        raise GmailApi::Error, 502 unless valid

        decoded = Base64.urlsafe_decode64(data)
        raise GmailApi::Error, 502 unless decoded.bytesize == size

        decoded
      rescue ArgumentError
        raise GmailApi::Error.new(502), cause: nil
      end

      def safe_filename(part)
        part['filename'].to_s.delete("\r\n\u0000").slice(0, 200).then { |name| name.empty? ? '添付ファイル' : name }
      end

      def omit(part, reason)
        @omissions << { 'name' => safe_filename(part), 'reason' => reason, 'size' => part.dig('body', 'size') }
        nil
      end
    end
  end
end
