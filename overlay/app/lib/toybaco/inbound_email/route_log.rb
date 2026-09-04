# frozen_string_literal: true

require_relative 'route_log_helpers'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module InboundEmail
    # FilterLogEvents が token 行で mailbox 名と Conversation を結べるよう、
    # mail.message_id が書き換わっても toybaco-fixture-<token> を同じ行へ残す。
    module RouteLog
      include RouteLogHelpers

      def mailbox_route_log(mailbox:, message_id:, conversation: nil, raw: nil)
        name = MAILBOX_LOG_NAMES.include?(mailbox.to_s) ? mailbox.to_s : 'DefaultMailbox'
        token = fixture_token(message_id, raw)
        mid = sanitize_message_id(prefer_fixture_message_id(message_id, raw, token))
        marker = token && "toybaco-fixture-#{token}"
        parts = ["Toybaco inbound route mailbox=#{name}"]
        parts << (conversation ? 'Conversation=yes' : 'Conversation=no') unless conversation.nil?
        parts << "message_id=#{mid}"
        parts << marker if marker && mid.downcase.exclude?(marker)
        parts.join(' ')
      end

      def log_mailbox_route(mail, mailbox:, conversation: nil, raw: nil)
        source = [raw, mail_raw_source(mail)].compact.join("\n")
        mailbox_route_log(
          mailbox: mailbox,
          message_id: route_message_id(mail, raw: source),
          conversation: conversation,
          raw: source
        )
      end

      def route_message_id(mail, raw: nil)
        source = raw || mail_raw_source(mail)
        candidates = [
          extract_header_message_id(source),
          mail_header(mail, 'Message-ID'),
          mail_header(mail, 'X-Toybaco-Fixture'),
          mail_accessor(mail, :message_id)
        ]
        token = fixture_token(*candidates, source)
        prefer_fixture_message_id(candidates.compact.first, source, token)
      end

      def mail_raw_source(mail)
        if mail.respond_to?(:raw_source)
          mail.raw_source
        elsif mail.respond_to?(:encoded)
          mail.encoded
        elsif mail.is_a?(Hash)
          mail[:raw_source] || mail['raw_source'] || mail[:source]
        end
      end

      def fixture_token(*sources)
        sources.each do |source|
          match = source.to_s.match(FIXTURE_TOKEN)
          return match[1].downcase if match
        end
        nil
      end
    end
  end
end
