# frozen_string_literal: true

require_relative 'ai_ledger'
require_relative 'store_facts'
require_relative 'reply_result'
require_relative 'trial_connection'
require_relative '../ai_reply_mode'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class BotReply
      def initialize(account, bot:, conversation:, message:)
        @account = account
        @bot = bot
        @conversation = conversation
        @message = message
        @ledger = AiLedger.new(account)
      end

      def update(params)
        case params[:action_type]
        when 'reserve' then reserve
        when 'consumed', 'released' then settle(params)
        else { 'result' => 'denied', 'reason' => 'invalid_action' }
        end
      end

      private

      def request_key
        Digest::SHA256.hexdigest("toybaco-reply:#{@account.id}:#{@message.id}")
      end

      def facts
        StoreFacts.new(@account).read
      end

      def context_digest
        @message.reload
        Digest::SHA256.hexdigest(JSON.generate([@message.id, @message.content, facts['revision']]))
      end

      def reserve
        @account.with_lock { @conversation.with_lock { reserve_current } }
      end

      def reserve_current
        return denied('facts_required') unless facts['confirmed']
        return denied('conversation_changed') unless current_conversation?

        mode = AiReplyMode.read_from(@account)
        return denied('trial_connection_unavailable') if mode == AiReplyMode::AUTO && !automatic_connection?

        kind = mode == AiReplyMode::AUTO ? 'automatic_reply' : 'reply_draft'
        result = @ledger.reserve(request_key: request_key, kind: kind, context_digest: context_digest)
        result.merge('meter' => 'business_generation', 'facts' => facts['fields'])
      end

      def settle(params)
        @account.with_lock do
          @conversation.with_lock do
            operation = Toybaco::GrowthAiOperation.find_by(id: params[:operation_id], account_id: @account.id, request_key: request_key)
            return denied('invalid_reservation') unless operation

            outcome = params[:action_type]
            outcome = 'released' if outcome == 'consumed' && !current_generation?(operation)
            @ledger.settle(operation_id: operation.id, token: params[:token], outcome: outcome) do
              ReplyResult.new(@account, @conversation, @bot, operation).persist!(params[:reply], requested_mode: params[:mode])
            end.merge('persisted' => outcome == 'consumed')
          end
        end
      end

      def current_generation?(operation)
        current_conversation? && facts['confirmed'] && operation.context_digest == context_digest
      end

      def automatic_connection?
        Entitlements.for_account(@account)&.dig('features', 'ai_auto_reply') == true || TrialConnection.allowed?(@account, @conversation.inbox)
      end

      def current_conversation?
        return false unless @conversation.pending? && @account.active?
        return false unless @bot.agent_bot_inboxes.where(status: :active).exists?(inbox_id: @conversation.inbox_id)

        latest = @conversation.messages.where(message_type: :incoming, private: false).order(created_at: :desc, id: :desc).first
        latest&.id == @message.id
      end

      def denied(reason)
        { 'result' => 'denied', 'reason' => reason }
      end
    end
  end
end
