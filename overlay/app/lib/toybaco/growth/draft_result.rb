# frozen_string_literal: true

require_relative 'ai_ledger'
require_relative 'reply_result'
require_relative 'draft_input'
require_relative 'draft_access'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class DraftResult
      def initialize(request)
        @request = request
        @account = request.account
      end

      def complete!(input, result)
        @account.with_lock do
          @request.with_lock do
            return unless @request.state == 'running'

            conversation = @account.conversations.find_by(id: @request.conversation_id)
            return fail!('conversation_changed') unless conversation

            conversation.with_lock { save_if_current!(conversation, input, result) }
          end
        end
      end

      def fail!(reason)
        @account.with_lock do
          @request.with_lock do
            return if %w[completed failed].include?(@request.state)

            operation = @request.operation
            operation.update!(state: 'released') if operation.state == 'reserved'
            @request.update!(state: 'failed', encrypted_input: nil, error_code: reason)
          end
        end
      end

      private

      def save_if_current!(conversation, input, result)
        user = User.find_by(id: @request.user_id)
        valid = DraftAccess.enabled? && DraftAccess.generation_allowed?(@account, user, conversation) &&
                DraftInput.new(@account, conversation, user).current?(input)
        return fail!('conversation_changed') unless valid

        outcome = AiLedger.new(@account).settle(operation_id: @request.operation_id, token: input.fetch('token'), outcome: 'consumed') do
          persist!(conversation, user, result)
        end
        fail!('allowance_changed') unless outcome['result'] == 'consumed'
      end

      def persist!(conversation, user, result)
        message = conversation.messages.create!(account_id: @account.id, inbox_id: conversation.inbox_id, sender: user,
                                                message_type: :outgoing, private: true, content: ReplyResult::DRAFT_PREFIX + result.fetch('content'),
                                                additional_attributes: { ReplyResult::KEY => {
                                                  'operation_id' => @request.operation_id, 'request_id' => @request.id, 'state' => 'draft',
                                                  'needs_review' => result.fetch('needs_review')
                                                } })
        @request.update!(state: 'completed', encrypted_input: nil)
        "message:#{message.id}"
      end
    end
  end
end
