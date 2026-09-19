# frozen_string_literal: true

require_relative 'ai_ledger'
require_relative 'post_draft_input'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class PostDraftResult
      def initialize(request)
        @request = request
        @account = request.account
      end

      def complete!(input, result)
        @account.with_lock do
          @request.with_lock do
            return unless @request.state == 'running'
            return fail!('context_changed') unless PostDraftInput.current?(@account, @request)

            outcome = AiLedger.new(@account).settle(operation_id: @request.operation_id, token: input.fetch('token'), outcome: 'consumed') do
              persist!(result)
            end
            fail!('allowance_changed') unless outcome['result'] == 'consumed'
          end
        end
      end

      def fail!(reason)
        @account.with_lock do
          @request.with_lock do
            return if %w[completed failed].include?(@request.state)

            @request.operation.update!(state: 'released') if @request.operation.state == 'reserved'
            @request.update!(state: 'failed', encrypted_input: nil, error_code: reason)
          end
        end
      end

      private

      def persist!(result)
        @request.update!(state: 'completed', encrypted_input: nil, encrypted_result: PostDraftInput.encrypt(@request, result, kind: 'result'),
                         result_expires_at: Time.now.utc + 24.hours)
        "post-draft:#{@request.id}"
      end
    end
  end
end
