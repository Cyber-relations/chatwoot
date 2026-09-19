# frozen_string_literal: true

require_relative 'completion'
require_relative 'mail_gateway'
require_relative 'mail_target'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    module Handoff
      class MailSetup
        def initialize(record, gateway: MailGateway.new(record.provider))
          @record = record
          @gateway = gateway
        end

        # Payload comes only from the provider's code exchange, never a public form.
        def save!(browser_nonce:, payload:)
          raise Forbidden unless MailGateway::PROVIDERS.include?(@record.provider)

          Completion.new(@record).commit!(browser_nonce: browser_nonce) do |account, _provider, _inbox_id|
            raise Unavailable unless @gateway.allowed?(account)

            MailTarget.new(@record).verify!(payload.fetch(:profile))
            @gateway.connect!(account: account, payload: payload)
          end
        end
      end
    end
  end
end
