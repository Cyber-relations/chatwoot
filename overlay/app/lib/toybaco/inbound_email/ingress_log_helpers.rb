# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module InboundEmail
    # IngressLog の STDOUT / logger 書き出しと原本組み立て。
    # 本体の ModuleLength を抑える。
    module IngressLogHelpers
      private

      def already_emitted_ses_route?(raw)
        return false unless Thread.current[:toybaco_ses_route_request]

        token = fixture_token(raw)
        key = token ? "fixture:#{token}" : "raw:#{raw.bytesize}"
        return true if Thread.current[:toybaco_ses_route_emitted] == key

        Thread.current[:toybaco_ses_route_emitted] = key
        false
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

      def write_captured_logger(text)
        captured_loggers.each do |logger|
          logger.info(text)
        rescue StandardError
          nil
        end
      end

      def captured_loggers
        loggers = []
        job_logger = active_job_logger
        loggers << job_logger if job_logger
        rails = rails_info_logger
        loggers << rails if rails
        loggers.compact.uniq
      end

      def active_job_logger
        ActiveJob::Base.logger if defined?(ActiveJob::Base) && ActiveJob::Base.respond_to?(:logger)
      end

      def rails_info_logger
        Rails.logger if defined?(Rails) && Rails.respond_to?(:logger)
      end

      def ingress_fallback_line(raw)
        token = fixture_token(raw)
        mailbox = raw.match?(/shop-\d+@inbox\.(?:staging\.)?toybaco\.jp/i) ? 'SupportMailbox' : 'DefaultMailbox'
        parts = [ROUTE_LOG_PREFIX]
        parts << "toybaco-fixture-#{token}" if token
        parts << "mailbox=#{mailbox}"
        parts << 'Conversation=no'
        parts << 'message_id=unavailable'
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
