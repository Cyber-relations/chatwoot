# frozen_string_literal: true

require_relative 'gmail_send'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    module GmailMessageBoundary
      module Builder
        private

        def content_attributes
          super.except(GmailSend::KEY, GmailSend::KEY.to_sym)
        end

        def message_params
          values = super
          values.delete(:source_id) if Gmail.connected?(@conversation.inbox.channel)
          values
        end
      end

      # The stock retry endpoint clears content_attributes and source_id. Doing
      # that to an uncertain Gmail send would erase its duplicate-send fence.
      module Retry
        private

        def claim_message_retry
          return super unless Gmail.connected?(@conversation.inbox.channel)

          message.with_lock do
            saved = message.content_attributes[GmailSend::KEY] || {}
            return false unless message.failed?
            return false if message.source_id.present? || %w[sending uncertain accepted].include?(saved['state'])

            attributes = message.content_attributes.except('external_error')
            message.update!(status: :sent, content_attributes: attributes)
            true
          end
        end
      end
    end
  end
end
