# frozen_string_literal: true

require_relative 'ingress_log_helpers'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module InboundEmail
    # SES create 204 と同じ過程で FilterPattern `toybaco-fixture-<token>` の
    # 1行へ mailbox と Conversation を載せる。行頭は toybaco-route-log。
    # 正本は lograge / start_processing（token が既に CW に出る口）。
    module IngressLog
      include RouteLogHelpers
      include IngressLogHelpers

      def log_ingress_mailbox_route(source, channel_found: nil)
        log_ses_create_route(source: source, channel_found: channel_found)
      end

      def log_ses_create_route(source:, channel_found: nil)
        raw = source.to_s
        return if already_emitted_ses_route?(raw)

        emit_cloudwatch_line(ses_create_route_line(raw, channel_found: channel_found))
      rescue StandardError
        emit_cloudwatch_line(ingress_fallback_line(source.to_s))
      end

      def build_ses_create_route_line(source, channel_found: nil)
        ses_create_route_line(source.to_s, channel_found: channel_found)
      rescue StandardError
        ingress_fallback_line(source.to_s)
      end

      def emit_cloudwatch_line(line)
        text = flatten_log_line(line)
        return text if text.empty?

        write_stdout_line(text)
        write_captured_logger(text)
        text
      end

      private

      def ses_create_route_line(raw, channel_found:)
        mail = ingress_mail_from(raw)
        found = channel_found.nil? ? ingress_support_found?(mail) : channel_found
        line = log_mailbox_route(
          mail,
          mailbox: ingress_mailbox_name(mailbox_route(mail, channel_found: found)),
          conversation: false,
          raw: raw
        )
        guarantee_filter_pattern(line, raw)
      end

      def ingress_support_found?(mail)
        ingress_channel_found?(mail) || support_bound_recipient?(mail)
      end

      def support_bound_recipient?(mail)
        mailbox_recipients(mail).any? do |address|
          local, domain = address.split('@', 2)
          local.to_s.match?(/\A#{LOCAL_PART_PREFIX}-\d+\z/o) && ALLOWED_DOMAINS.include?(domain)
        end
      end
    end
  end
end
