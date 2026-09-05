# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module InboundEmail
    # RouteLog の Message-ID / ヘッダ読み取り。本体の ModuleLength を抑える。
    module RouteLogHelpers
      MAILBOX_LOG_NAMES = %w[SupportMailbox ReplyMailbox DefaultMailbox].freeze
      ROUTE_LOG_PREFIX = 'toybaco-route-log'
      MESSAGE_ID = /\A<?[^\s<>]{1,200}>?\z/
      FIXTURE_TOKEN = /toybaco-fixture-([0-9a-f]{8,32})/i
      NAMED_HEADER = /\A([A-Za-z0-9-]+):\s*(.+?)\s*\z/

      private

      def mail_accessor(mail, key)
        if mail.respond_to?(key)
          mail.public_send(key)
        elsif mail.is_a?(Hash)
          mail[key] || mail[key.to_s]
        end
      end

      def mail_header(mail, name)
        if mail.respond_to?(:[])
          field = mail[name]
          return field.value if field.respond_to?(:value)

          field
        elsif mail.is_a?(Hash)
          mail[name] || mail[name.to_s]
        end
      end

      def extract_header_message_id(raw)
        header_field(raw, 'Message-ID')
      end

      def header_field(raw, name)
        raw.to_s.each_line do |line|
          match = NAMED_HEADER.match(line)
          return match[2] if match && match[1].casecmp?(name)

          break if line.strip.empty?
        end
        nil
      end

      def prefer_fixture_message_id(message_id, raw, token)
        candidates = [extract_header_message_id(raw), message_id]
        if token
          found = candidates.find do |value|
            text = value.to_s.strip
            MESSAGE_ID.match?(text) && text.downcase.include?("toybaco-fixture-#{token}")
          end
          return found.to_s.strip if found
        end

        text = message_id.to_s.strip
        return text if MESSAGE_ID.match?(text)

        message_id
      end

      def sanitize_message_id(value)
        text = value.to_s.strip
        return 'unavailable' unless MESSAGE_ID.match?(text)

        text
      end
    end
  end
end
