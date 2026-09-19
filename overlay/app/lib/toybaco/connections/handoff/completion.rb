# frozen_string_literal: true

require_relative 'access'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    module Handoff
      class Completion
        def initialize(record)
          @record = record
        end

        # Only a provider adapter may call this. Its DB changes and the one-use
        # receipt commit together; the recipient never becomes an account user.
        def commit!(browser_nonce:)
          @record.account.with_lock do
            @record.with_lock do
              Access.claim!(@record, browser_nonce)
              inbox = yield(@record.account, @record.provider, @record.inbox_id)
              validate_result!(inbox)
              Access.claim!(@record, browser_nonce)
              @record.update!(Access::PRIVATE_FIELDS.merge(state: 'completed', claim_digest: @record.claim_digest, completed_at: Time.now.utc,
                                                           result_inbox_id: inbox.id))
              inbox
            end
          end
        end

        private

        def validate_result!(inbox)
          raise Forbidden unless inbox.is_a?(Inbox) && inbox.persisted? && inbox.account_id == @record.account_id
          raise Forbidden unless inbox.channel_type == Access::PROVIDERS.fetch(@record.provider)
          raise Forbidden if @record.inbox_id && inbox.id != @record.inbox_id

          Access.target!(@record.account, @record.provider, inbox.id)
        end
      end
    end
  end
end
