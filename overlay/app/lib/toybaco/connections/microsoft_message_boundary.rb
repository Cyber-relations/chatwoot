# frozen_string_literal: true

require_relative 'microsoft_send'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    module MicrosoftMessageBoundary
      module Builder
        private

        def content_attributes
          super.except(MicrosoftSend::KEY, MicrosoftSend::KEY.to_sym, MicrosoftIngest::KEY, MicrosoftIngest::KEY.to_sym)
        end

        def message_params
          values = super
          values.delete(:source_id) if Microsoft.connected?(@conversation.inbox.channel)
          values
        end
      end

      module Retry
        private

        def claim_message_retry
          return super unless Microsoft.connected?(@conversation.inbox.channel)

          message.with_lock do
            saved = message.content_attributes[MicrosoftSend::KEY] || {}
            return false unless message.failed?
            return false if message.source_id.present? || %w[preparing sending uncertain accepted].include?(saved['state'])

            attributes = message.content_attributes.except('external_error')
            message.update!(status: :sent, content_attributes: attributes)
            true
          end
        end
      end
    end
  end
end
