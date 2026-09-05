# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module InboundEmail
    # Completed 204 を書く ActionController::LogSubscriber#process_action の
    # 直後に、同じ `info` 呼び出し経路で toybaco-route-log を出す。
    # #107 の Notifications.subscribe + Base.logger.info 直叩きは、この口ではない。
    module SesIngressLogSubscriber
      def process_action(event)
        super
        emit_toybaco_ses_completed_route(event)
      end

      def emit_toybaco_ses_completed_route(event)
        payload = log_subscriber_payload(event)
        return unless payload[:status].to_i == 204
        return unless Toybaco::InboundEmail.ses_completed_route_target?(payload)

        line = Toybaco::InboundEmail.build_ses_create_route_line(
          Toybaco::InboundEmail.ses_completed_route_source(payload)
        )
        info(line) unless line.to_s.empty?
      rescue StandardError
        fallback = Toybaco::InboundEmail.build_ses_create_route_line('')
        info(fallback) unless fallback.to_s.empty?
      end

      private

      def log_subscriber_payload(event)
        return event.payload if event.respond_to?(:payload) && event.payload.is_a?(Hash)
        return event if event.is_a?(Hash)

        {}
      end
    end
  end
end
