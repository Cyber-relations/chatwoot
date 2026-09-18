# frozen_string_literal: true

require_relative 'reply_result'
require_relative 'trial_connection'
require_relative '../entitlements'
require_relative '../ai_reply_mode'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class ReplyDelivery
      def initialize(message, now: Time.now.utc)
        @message = message
        @account = message.account
        @now = now
      end

      def claim!
        @account.with_lock do
          @message.with_lock do
            state = saved
            return false unless state.is_a?(Hash) && state['state'] == 'queued'
            return hold!(state) unless allowed?(state)

            save!(state.merge('state' => 'dispatching', 'attempted_at' => @now.iso8601))
            true
          end
        end
      end

      def attempted!(uncertain: false)
        @message.with_lock do
          return unless saved&.dig('state') == 'dispatching'

          save!(saved.merge('state' => uncertain ? 'uncertain' : 'attempted'))
        end
      end

      private

      def saved
        @message.additional_attributes[ReplyResult::KEY]
      end

      def allowed?(state)
        operation = Toybaco::GrowthAiOperation.find_by(id: state['operation_id'], account_id: @account.id)
        return false unless valid_operation?(operation)

        rights?(operation) && bot_active? && !@message.private?
      end

      def valid_operation?(operation)
        operation && operation.state == 'consumed' && operation.kind == 'automatic_reply' &&
          operation.result_reference == "message:#{@message.id}" && operation.lease_expires_at > @now
      end

      def rights?(operation)
        terms = Entitlements.for_account(@account)
        return false unless automatic_account?(terms)
        return false if operation.grant.revoked_at

        terms.dig('features', 'ai_auto_reply') == true || valid_trial?(operation.grant)
      end

      def valid_trial?(grant)
        grant.source == 'trial' && grant.ends_at > @now && TrialConnection.allowed?(@account, @message.inbox)
      end

      def automatic_account?(terms)
        @account.active? && terms&.dig('ai_meter') == GrowthTerms::METER && AiReplyMode.read_from(@account) == 'auto'
      end

      def bot_active?
        bot = @message.sender
        return false unless @message.conversation.pending? && bot.instance_of?(AgentBot)

        bot.agent_bot_inboxes.where(status: :active).exists?(inbox_id: @message.inbox_id)
      end

      def hold!(state)
        text = @message.content.to_s.delete_prefix(ReplyResult::AUTO_PREFIX)
        @message.update!(private: true, content: ReplyResult::DRAFT_PREFIX + text,
                         additional_attributes: @message.additional_attributes.merge(ReplyResult::KEY => state.merge('state' => 'held')))
        @message.conversation.open! if @message.conversation.pending?
        false
      end

      def save!(state)
        @message.update!(additional_attributes: @message.additional_attributes.merge(ReplyResult::KEY => state))
      end
    end
  end
end
