# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module InboundEmail
    # Chatwoot の lograge は ActionController::LogSubscriber を外し、
    # params JSON を Rails/Lograge.logger へ書く。#108 の prepend は
    # その購読が無いので CW に 0 行。token が既に出る口へ載せる。
    module SesIngressLogrageSubscriber
      def process_action(event)
        super
        Toybaco::InboundEmail.emit_ses_route_from_process_action(event, logger: logger)
      end
    end

    module SesIngressLograge
      LOGRAGE_SUBSCRIBER = 'Lograge::LogSubscribers::ActionController'

      def install_ses_lograge_hook!
        prepend_ses_lograge_subscriber!
        wrap_ses_lograge_custom_options!
      end

      def prepend_ses_lograge_subscriber!
        return if @ses_lograge_subscriber_hooked

        klass = lograge_action_controller_subscriber
        return unless klass

        hook = Toybaco::InboundEmail::SesIngressLogrageSubscriber
        klass.prepend(hook) unless klass < hook
        @ses_lograge_subscriber_hooked = true
      end

      def emit_ses_route_from_process_action(event, logger: nil)
        payload = process_action_payload(event)
        return unless ses_route_event?(payload)

        emit_ses_route_once(ses_completed_route_source(payload), logger: logger)
      rescue StandardError
        emit_ses_route_once('', logger: logger)
      end

      private

      def lograge_action_controller_subscriber
        return unless defined?(Lograge) && Lograge.const_defined?(:LogSubscribers)

        subscribers = Lograge::LogSubscribers
        return unless subscribers.const_defined?(:ActionController)

        subscribers.const_get(:ActionController)
      rescue NameError
        nil
      end

      def wrap_ses_lograge_custom_options!
        return if @ses_lograge_options_wrapped
        return unless defined?(Rails) && Rails.application.respond_to?(:config)
        return unless Rails.application.config.respond_to?(:lograge)

        lograge = Rails.application.config.lograge
        return unless lograge.respond_to?(:custom_options)

        previous = lograge.custom_options
        lograge.custom_options = lambda do |event|
          merge_ses_lograge_options(event, previous)
        end
        @ses_lograge_options_wrapped = true
      rescue StandardError
        nil
      end

      def merge_ses_lograge_options(event, previous)
        base = previous.respond_to?(:call) ? previous.call(event) : {}
        base = {} unless base.is_a?(Hash)
        payload = process_action_payload(event)
        return base unless ses_route_event?(payload)

        line = build_ses_create_route_line(ses_completed_route_source(payload))
        line.to_s.empty? ? base : base.merge(toybaco_route_log: line)
      rescue StandardError
        base.is_a?(Hash) ? base : {}
      end

      def process_action_payload(event)
        return event.payload if event.respond_to?(:payload) && event.payload.is_a?(Hash)
        return event if event.is_a?(Hash)

        {}
      end
    end
  end
end
