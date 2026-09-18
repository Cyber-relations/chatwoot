# frozen_string_literal: true

require_relative 'reply_result'
require_relative 'store_facts'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class TrialExample
      def initialize(account)
        @account = account
      end

      def find(id, revision:)
        message = @account.messages.find_by(id: id, sender_type: 'AgentBot', message_type: :outgoing, private: true)
        return unless message&.content&.start_with?(ReplyResult::DRAFT_PREFIX)

        operation = operation_for(message)
        return unless operation && operation.kind == 'reply_draft' && matching_input?(message, operation, revision)

        message
      end

      def list(revision:)
        candidates = @account.messages.where(sender_type: 'AgentBot', message_type: :outgoing, private: true).order(id: :desc).limit(30)
        candidates.filter_map { |message| find(message.id, revision: revision) }.first(3)
      end

      private

      def operation_for(message)
        marker = message.additional_attributes&.dig(ReplyResult::KEY)
        return unless marker.is_a?(Hash)

        Toybaco::GrowthAiOperation.find_by(id: marker['operation_id'], account_id: @account.id,
                                           state: 'consumed', result_reference: "message:#{message.id}")
      end

      def matching_input?(message, operation, revision)
        incoming = message.conversation.messages.where(message_type: :incoming, private: false).order(created_at: :desc, id: :desc).first
        return false unless incoming && incoming.source_id.present?

        digest = Digest::SHA256.hexdigest(JSON.generate([incoming.id, incoming.content, revision]))
        key = Digest::SHA256.hexdigest("toybaco-reply:#{@account.id}:#{incoming.id}")
        operation.context_digest == digest && operation.request_key == key
      end
    end
  end
end
