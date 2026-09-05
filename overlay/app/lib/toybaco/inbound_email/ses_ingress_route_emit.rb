# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module InboundEmail
    # SES 204 の route-log を1回だけ、CW に既に出る logger へ書く。
    module SesIngressRouteEmit
      REQUEST_FLAG = :toybaco_ses_route_request

      def emit_ses_route_once(source, logger: nil)
        raw = source.to_s
        mark_ses_route_request!
        return if already_emitted_ses_route?(raw)

        line = build_ses_create_route_line(raw)
        return if line.to_s.empty?

        logger.info(line) if logger.respond_to?(:info)
        emit_cloudwatch_line(line)
        line
      rescue StandardError
        fallback = build_ses_create_route_line('')
        emit_cloudwatch_line(fallback) unless fallback.to_s.empty?
        fallback
      end

      def ses_route_event?(payload)
        return true if ses_completed_route_target?(payload)
        return true unless stored_ses_route_token.to_s.empty?

        false
      end

      def mark_ses_route_request!
        Thread.current[REQUEST_FLAG] = true
      end

      def clear_ses_route_request!
        Thread.current[REQUEST_FLAG] = nil
        Thread.current[:toybaco_ses_route_emitted] = nil
      end
    end
  end
end
