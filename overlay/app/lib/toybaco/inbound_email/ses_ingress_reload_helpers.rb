# frozen_string_literal: true

require 'json'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module InboundEmail
    # process_action 204 の原本組み立て。ReloadHook の ModuleLength を抑える。
    module SesIngressReloadHelpers
      SES_PROCESS_CONTROLLERS = [
        'toybaco/ses_inbound_emails',
        'action_mailbox/ingresses/ses/inbound_emails',
        'ActionMailbox::Ingresses::Ses::InboundEmailsController',
        'Toybaco::SesInboundEmailsController'
      ].freeze

      private

      def ses_process_action?(payload)
        return true if SES_PROCESS_CONTROLLERS.include?(payload[:controller].to_s)

        path = payload[:path].to_s
        path.end_with?('/ses/inbound_emails') ||
          path.include?('/rails/action_mailbox/ses/inbound_emails')
      end

      def process_action_source(payload)
        [
          Thread.current[:toybaco_ses_route_raw],
          header_fixture_token(payload[:headers]),
          params_message_source(payload[:params])
        ].compact.map(&:to_s).reject(&:empty?).join("\n")
      end

      def header_fixture_token(headers)
        return unless headers

        headers['X-Toybaco-Fixture'] ||
          headers['HTTP_X_TOYBACO_FIXTURE'] ||
          (headers['x-toybaco-fixture'] if headers.respond_to?(:[]))
      end

      def params_message_source(params)
        hash = request_params_hash(params)
        return '' unless hash

        encoded_params_message(hash) || hash['content'] || hash[:content] || ''
      end

      def encoded_params_message(hash)
        message = hash['Message'] || hash[:Message] || hash['message']
        return message if message.is_a?(String)

        JSON.generate(message) if message.is_a?(Hash)
      end

      def request_params_hash(params)
        return params if params.is_a?(Hash)
        return params.to_unsafe_h if params.respond_to?(:to_unsafe_h)
        return params.to_h if params.respond_to?(:to_h)

        nil
      end
    end
  end
end
