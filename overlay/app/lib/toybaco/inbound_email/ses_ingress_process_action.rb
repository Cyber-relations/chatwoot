# frozen_string_literal: true

require_relative 'ses_ingress_reload_helpers'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module InboundEmail
    # gem コントローラへ prepend_before_action し、token を request store へ残す。
    # Reloader は明示定数で載せ直す（#106 の裸メソッド NoMethodError）。
    module SesIngressTokenCapture
      def store_toybaco_ses_ingress_token
        Toybaco::InboundEmail.store_ses_ingress_token_from_request(self)
      end
    end

    # Completed 204 と同じ process_action.action_controller で route-log を出す。
    # #106 は Event 1個配信を 5引数コンストラクタへ渡して落ち、Notifications が飲んだ。
    # $stdout 並行 sink は /ecs/toybaco-staging の Completed 204 行と同じ口ではない。
    module SesIngressProcessAction
      include SesIngressReloadHelpers

      PROCESS_ACTION_EVENT = 'process_action.action_controller'

      def install_ses_process_action_subscriber!
        return if @ses_process_action_subscribed
        return unless defined?(ActiveSupport::Notifications)

        @ses_process_action_subscribed = true
        ActiveSupport::Notifications.subscribe(PROCESS_ACTION_EVENT) do |*args|
          Toybaco::InboundEmail.emit_process_action_ses_route(args)
        end
      end

      def install_ses_ingress_token_capture!
        klass = load_ses_ingress_controller!
        return unless klass

        hook = Toybaco::InboundEmail::SesIngressTokenCapture
        klass.class_eval do
          prepend hook unless self < hook
          unless instance_variable_defined?(:@_toybaco_ses_token_before_action)
            @_toybaco_ses_token_before_action = true
            prepend_before_action :store_toybaco_ses_ingress_token if respond_to?(:prepend_before_action)
          end
        end
      end

      def emit_process_action_ses_route(args)
        payload = process_action_payload(args)
        return unless payload[:status].to_i == 204
        return unless ses_process_action?(payload)

        Toybaco::InboundEmail.log_ses_create_route_via_action_controller(
          source: process_action_source(payload)
        )
      end

      def store_ses_ingress_token_from_request(controller)
        request = controller.request if controller.respond_to?(:request)
        source = ses_request_token_source(request)
        Thread.current[:toybaco_ses_route_raw] = source unless source.empty?
        request.env['toybaco.ses_route_source'] = source if request.respond_to?(:env) && request.env
        source
      end

      def process_action_payload(args)
        values = args.is_a?(Array) ? args : [args]
        first = values[0]
        return first.payload if first.respond_to?(:payload)
        return values[4] if values.size >= 5 && values[4].is_a?(Hash)
        return first if first.is_a?(Hash)

        {}
      end

      def ses_request_token_source(request)
        return '' unless request

        header = request.headers if request.respond_to?(:headers)
        [
          header && header['X-Toybaco-Fixture'],
          (request.raw_post if request.respond_to?(:raw_post))
        ].compact.map(&:to_s).reject(&:empty?).join("\n")
      end
    end
  end
end
