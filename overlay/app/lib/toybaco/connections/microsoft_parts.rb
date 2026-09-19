# frozen_string_literal: true

require 'mail'
require 'digest'
require_relative 'microsoft_attachments'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    class MicrosoftParts
      HEADERS = %w[in-reply-to references auto-submitted x-autoreply x-original-from x-original-sender x-forwarded-for x-failed-recipients].freeze
      attr_reader :omissions

      def initialize(api:, access_token:, data:, attachment_limit: MicrosoftApi::MAX_ATTACHMENT_BYTES, attachment_count: 15)
        @api = api
        @token = access_token
        @data = data
        @attachments = MicrosoftAttachments.new(api: api, access_token: access_token, message_id: data.fetch('id'),
                                                limit: attachment_limit, count: attachment_count)
        @omissions = @attachments.omissions
      end

      def message_id
        id = clean(@data['internetMessageId'])
        id = "microsoft-#{Digest::SHA256.hexdigest(@data.fetch('id'))}@toybaco.invalid" if id.empty?
        header = Mail.new
        header.message_id = id
        header.message_id
      end

      def mail
        result = Mail.new
        result.message_id = message_id
        envelope(result)
        headers(result)
        body(result)
        # hasAttachments excludes inline images. Always inspect the collection.
        @attachments.append_to(result)
        result
      end

      private

      def envelope(result)
        result.from = recipients([@data.fetch('from')])
        result.to = recipients(@data['toRecipients'])
        result.cc = recipients(@data['ccRecipients'])
        result.reply_to = recipients(@data['replyTo']) if Array(@data['replyTo']).any?
        result.subject = clean(@data['subject'])
        result.date = Time.iso8601(@data.fetch('receivedDateTime'))
      end

      def clean(value)
        value.to_s.gsub(/\r?\n[ \t]+/, ' ').delete("\r\n\u0000")
      end

      def recipients(values)
        rows = Array(values)
        raise MicrosoftApi::Error, 502 if rows.length > 100

        rows.map do |row|
          address = clean(row.fetch('emailAddress').fetch('address'))
          raise MicrosoftApi::Error, 502 unless address.match?(URI::MailTo::EMAIL_REGEXP)

          address
        end
      end

      def headers(result)
        Array(@data['internetMessageHeaders']).each do |header|
          name = header.fetch('name').to_s.downcase
          result[name] = clean(header['value']) if HEADERS.include?(name)
        end
      end

      def body(result)
        data = @data.fetch('body')
        type = data.fetch('contentType').to_s.downcase
        raise MicrosoftApi::Error, 502 unless %w[text html].include?(type) && data['content'].is_a?(String)

        part = Mail::Part.new
        part.content_type = type == 'html' ? 'text/html; charset=UTF-8' : 'text/plain; charset=UTF-8'
        part.body = data.fetch('content')
        type == 'html' ? result.html_part = part : result.text_part = part
      end
    end
  end
end
