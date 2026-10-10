# frozen_string_literal: true

require_relative 'draft_result'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class DraftState
      def initialize(request)
        @request = request
      end

      def read
        state = @request.slice('id', 'state', 'draft_digest', 'incoming_id', 'error_code')
        return state unless @request.state == 'completed'

        operation = @request.operation
        id = operation.result_reference.to_s.delete_prefix('message:')
        message = @request.account.messages.find_by(id: id, conversation_id: @request.conversation_id, private: true,
                                                    sender_type: 'User', sender_id: @request.user_id)
        return state.merge('state' => 'failed', 'error_code' => 'result_unavailable') unless message

        state.merge('content' => message.content.delete_prefix(ReplyResult::DRAFT_PREFIX), 'message_id' => message.id, 'current' => current?(message),
                    'needs_review' => message.additional_attributes.dig(ReplyResult::KEY, 'needs_review') == true,
                    'facts_revision' => @request.facts_revision).merge(facts_fields(message))
      end

      private

      # 返信案を作ったときに参照した店舗情報の項目(キーだけ)。記録の無い旧い返信案には付けない。
      def facts_fields(message)
        fields = message.additional_attributes.dig(ReplyResult::KEY, 'facts_fields')
        fields.is_a?(Array) ? { 'facts_fields' => fields.select { |key| StoreFacts::LIMITS.key?(key) } } : {}
      end

      def current?(message)
        conversation = message.conversation
        facts = StoreFacts.new(@request.account).read
        input = DraftInput.new(@request.account, conversation, message.sender).build('')
        input['draft_digest'] = @request.draft_digest
        facts['confirmed'] && facts['revision'] == @request.facts_revision && input['public_tail_id'] == @request.public_tail_id &&
          DraftInput.new(@request.account, conversation, message.sender).digest(input) == @request.operation.context_digest
      rescue ArgumentError
        false
      end
    end
  end
end
