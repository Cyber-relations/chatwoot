# frozen_string_literal: true

require 'json'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module InboundEmail
    # SES/SNS 通知から会話へ載せる宛先を決める。未知宛先は拒否する。
    module Ingest
      DESTINATION_KEYS = %w[destination to cc X-Original-To x-original-to].freeze

      def route(notification, mailboxes:)
        destinations = destinations_for(notification)
        raise Rejected, '宛先がありません' if destinations.empty?

        destinations.each do |address|
          reply = reply_route(address)
          return reply if reply

          mailbox = Array(mailboxes).find { |entry| mailbox_match?(entry, address) }
          return { action: :new_conversation, mailbox: mailbox, address: address } if mailbox
        end

        raise Rejected, '受信箱に一致する宛先がありません'
      end

      def unwrap_sns(payload)
        body = parse_json_object(payload, 'SNS ペイロードを解釈できません')
        case body['Type']
        when 'SubscriptionConfirmation'
          { kind: :subscription_confirmation }
        when 'Notification'
          { kind: :received, notification: parse_json_object(body['Message'], 'SES 受信通知ではありません') }
        else
          raise Rejected, '未対応の SNS メッセージです'
        end
      end

      def destinations_for(notification)
        return [] unless notification.is_a?(Hash)

        mail = notification['mail'] || notification[:mail]
        raw = DESTINATION_KEYS.flat_map { |key| Array(notification[key]) }
        raw.concat(Array(mail['destination'])) if mail.is_a?(Hash)
        raw.flatten.compact.map { |value| normalize_address(value) }.uniq.reject(&:empty?)
      end

      def normalize_address(value)
        text = value.to_s.strip.downcase
        text = Regexp.last_match(1) if text =~ /<([^>]+)>/
        return '' unless MAILBOX_EMAIL.match?(text)

        local, domain = text.split('@', 2)
        local = local.split('+', 2).first unless local.start_with?('reply+')
        "#{local}@#{domain}"
      end

      def mailbox_match?(mailbox, address)
        candidates = [
          mailbox[:email] || mailbox['email'],
          mailbox[:forward_to_email] || mailbox['forward_to_email']
        ]
        candidates.compact.map { |value| normalize_address(value) }.include?(normalize_address(address))
      end

      private

      def reply_route(address)
        local_part, domain = address.split('@', 2)
        match = REPLY_LOCAL_PART.match(local_part.to_s)
        return unless match && ALLOWED_DOMAINS.include?(domain)

        { action: :reply, conversation_uuid: match[1].downcase, address: address }
      end

      def parse_json_object(value, error)
        body = value.is_a?(String) ? JSON.parse(value) : value
        return body if body.is_a?(Hash)

        raise Rejected, error
      rescue JSON::ParserError
        raise Rejected, error
      end
    end
  end
end
