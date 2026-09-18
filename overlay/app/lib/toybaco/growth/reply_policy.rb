# frozen_string_literal: true

require_relative 'ai_ledger'
require_relative 'store_facts'
require_relative '../ai_reply_mode'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class ReplyPolicy
      def initialize(account)
        @account = account
      end

      def automatic
        return unavailable('account_inactive') unless @account.active?
        return unavailable('facts_required') unless StoreFacts.new(@account).read['confirmed']

        summary = AiLedger.new(@account).summary(kind: 'automatic_reply')
        return unavailable('automatic_unavailable') unless summary['remaining'].positive?

        { 'automatic_enabled' => true, 'automatic_reason' => nil }
      end

      def write!(value, membership:)
        raise ArgumentError, 'invalid reply mode' unless AiReplyMode::MODES.include?(value)

        @account.with_lock do
          raise ArgumentError, 'store membership required' unless @account.account_users.exists?(id: membership.id)
          raise ArgumentError, 'automatic reply unavailable' if value == AiReplyMode::AUTO && !automatic['automatic_enabled']

          AiReplyMode.write_to!(@account, value)
        end
      end

      private

      def unavailable(reason)
        { 'automatic_enabled' => false, 'automatic_reason' => reason }
      end
    end
  end
end
