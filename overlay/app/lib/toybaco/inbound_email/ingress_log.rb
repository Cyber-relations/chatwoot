# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module InboundEmail
    # SES create 204 と同じ過程で FilterPattern `toybaco-fixture-<token>` の
    # 1行へ mailbox と Conversation を載せる。Rails.logger.info だけだと
    # ログレベル / tagged / lograge で CloudWatch から消える。
    module IngressLog
      def log_ingress_mailbox_route(source, channel_found: nil)
        log_ses_create_route(source: source, channel_found: channel_found)
      end

      def log_ses_create_route(source:, channel_found: nil)
        raw = source.to_s
        emit_cloudwatch_line(ses_create_route_line(raw, channel_found: channel_found))
      rescue StandardError
        emit_cloudwatch_line(ingress_fallback_line(source.to_s))
      end

      def emit_cloudwatch_line(line)
        text = flatten_log_line(line)
        return text if text.empty?

        write_stdout_line(text)
        write_rails_info(text)
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

      def guarantee_filter_pattern(line, raw)
        token = fixture_token(line, raw)
        return line unless token

        marker = "toybaco-fixture-#{token}"
        line.downcase.include?(marker) ? line : "#{line} #{marker}"
      end

      def flatten_log_line(line)
        line.to_s.gsub(/[\r\n]+/, ' ').squeeze(' ').strip
      end

      def write_stdout_line(text)
        $stdout.puts(text)
        $stdout.flush
      rescue StandardError
        nil
      end

      def write_rails_info(text)
        return unless defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger

        Rails.logger.info(text)
      rescue StandardError
        nil
      end

      def ingress_fallback_line(raw)
        token = fixture_token(raw)
        mailbox = raw.match?(/shop-\d+@inbox\.(?:staging\.)?toybaco\.jp/i) ? 'SupportMailbox' : 'DefaultMailbox'
        parts = ["Toybaco inbound route mailbox=#{mailbox}", 'Conversation=no', 'message_id=unavailable']
        parts << "toybaco-fixture-#{token}" if token
        parts.join(' ')
      end

      def ingress_mail_from(raw)
        return ::Mail.new(raw) if defined?(::Mail)

        {
          :raw_source => raw,
          :to => header_field(raw, 'To'),
          :cc => header_field(raw, 'Cc'),
          'X-Original-To' => header_field(raw, 'X-Original-To'),
          'Delivered-To' => header_field(raw, 'Delivered-To'),
          'X-Forwarded-To' => header_field(raw, 'X-Forwarded-To'),
          'X-Toybaco-Fixture' => header_field(raw, 'X-Toybaco-Fixture'),
          :message_id => extract_header_message_id(raw)
        }
      end

      def ingress_channel_found?(mail)
        return false unless defined?(EmailChannelFinder)

        EmailChannelFinder.new(mail).perform.present?
      rescue StandardError
        false
      end

      def ingress_mailbox_name(route)
        case route
        when :support then 'SupportMailbox'
        when :reply then 'ReplyMailbox'
        else 'DefaultMailbox'
        end
      end
    end
  end
end
