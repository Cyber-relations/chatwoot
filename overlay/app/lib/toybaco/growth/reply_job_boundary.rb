# frozen_string_literal: true

require_relative 'reply_delivery'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    module ReplyJobBoundary
      module Send
        def perform(message_id)
          message = Message.find(message_id)
          return super unless (message.additional_attributes || {}).key?(ReplyResult::KEY)

          delivery = ReplyDelivery.new(message)
          return unless delivery.claim!

          begin
            super
            delivery.attempted!
          rescue StandardError
            delivery.attempted!(uncertain: true)
            raise
          end
        end
      end

      module Retry
        private

        def claim_message_retry
          return false if (message.additional_attributes || {}).key?(ReplyResult::KEY)

          super
        end
      end
    end
  end
end
