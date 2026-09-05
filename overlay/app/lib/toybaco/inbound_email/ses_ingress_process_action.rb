# frozen_string_literal: true

require_relative 'ses_ingress_reload_helpers'
require_relative 'ses_ingress_log_subscriber'
require_relative 'ses_ingress_route_emit'
require_relative 'ses_ingress_lograge'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module InboundEmail
    # middleware が token を RequestStore / Thread.current に残すだけ。puts はしない。
    module SesIngressTokenStore
      RAW_KEY = :toybaco_ses_route_raw

      def store_ses_route_token(raw, env = nil)
        text = raw.to_s
        Thread.current[RAW_KEY] = text
        Thread.current[SesIngressRouteEmit::REQUEST_FLAG] = true
        write_ses_request_store(text)
        env['toybaco.ses_route_source'] = text if env.is_a?(Hash)
        text
      end

      def stored_ses_route_token
        stored = read_ses_request_store
        return stored unless stored.to_s.empty?

        Thread.current[RAW_KEY].to_s
      end

      def clear_ses_route_token
        Thread.current[RAW_KEY] = nil
        Thread.current[SesIngressRouteEmit::REQUEST_FLAG] = nil
        Thread.current[:toybaco_ses_route_emitted] = nil
        write_ses_request_store(nil)
      end

      private

      def write_ses_request_store(value)
        return unless defined?(RequestStore) && RequestStore.respond_to?(:store)

        RequestStore.store[SesIngressTokenStore::RAW_KEY] = value
      rescue StandardError
        nil
      end

      def read_ses_request_store
        return unless defined?(RequestStore) && RequestStore.respond_to?(:store)

        RequestStore.store[SesIngressTokenStore::RAW_KEY]
      rescue StandardError
        nil
      end
    end

    # lograge が外した AC LogSubscriber ではなく、params を書く口へ出す。
    module SesIngressProcessAction
      include SesIngressReloadHelpers
      include SesIngressTokenStore
      include SesIngressRouteEmit
      include SesIngressLograge

      PROCESS_ACTION_EVENT = 'process_action.action_controller'

      def install_ses_log_subscriber_hook!
        prepend_ses_log_subscriber!
        install_ses_lograge_hook!
        return if @ses_log_subscriber_hooked
        return if @ses_log_subscriber_on_load
        return unless defined?(ActiveSupport) && ActiveSupport.respond_to?(:on_load)

        @ses_log_subscriber_on_load = true
        ActiveSupport.on_load(:action_controller) do
          Toybaco::InboundEmail.prepend_ses_log_subscriber!
          Toybaco::InboundEmail.install_ses_lograge_hook!
        end
      end

      def prepend_ses_log_subscriber!
        return if @ses_log_subscriber_hooked
        return unless defined?(ActionController) && ActionController.const_defined?(:LogSubscriber)

        klass = ActionController::LogSubscriber
        hook = Toybaco::InboundEmail::SesIngressLogSubscriber
        klass.prepend(hook) unless klass < hook
        @ses_log_subscriber_hooked = true
      end

      def ses_completed_route_target?(payload)
        ses_process_action?(payload)
      end

      def ses_completed_route_source(payload)
        process_action_source(payload)
      end
    end
  end
end
