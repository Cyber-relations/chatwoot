# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class ReplyResult
      KEY = 'toybaco_growth_reply'
      DRAFT_PREFIX = "✦ AI が下書きを作成しました\n\n"
      AUTO_PREFIX = '[自動応答] '

      def initialize(account, conversation, bot, operation)
        @account = account
        @conversation = conversation
        @bot = bot
        @operation = operation
      end

      def persist!(content, requested_mode:)
        raise ArgumentError, 'invalid AI reply' unless valid_content?(content) && %w[auto draft].include?(requested_mode)

        automatic = automatic?(requested_mode)
        prefix = automatic ? AUTO_PREFIX : DRAFT_PREFIX
        message = @conversation.messages.create!(account_id: @account.id, inbox_id: @conversation.inbox_id,
                                                 sender: @bot, message_type: :outgoing, private: !automatic,
                                                 content: prefix + content.strip, additional_attributes: {
                                                   KEY => { 'operation_id' => @operation.id, 'state' => automatic ? 'queued' : 'draft' }
                                                 })
        @conversation.open! unless automatic
        "message:#{message.id}"
      end

      private

      def automatic?(requested_mode)
        @operation.kind == 'automatic_reply' && requested_mode == 'auto' && AiReplyMode.read_from(@account) == 'auto'
      end

      def valid_content?(value)
        value.is_a?(String) && value.strip.present? && value.length <= 1600 && value.exclude?("\u0000") &&
          value.exclude?('[[HANDOFF]]') && value.exclude?('[[NOTIFY]]')
      end
    end
  end
end
