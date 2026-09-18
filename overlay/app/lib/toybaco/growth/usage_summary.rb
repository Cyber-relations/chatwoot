# frozen_string_literal: true

require_relative 'ai_ledger'
require_relative 'reply_policy'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class UsageSummary
      def initialize(account)
        @account = account
      end

      def read
        result = AiLedger.new(@account).summary
        grants = result.fetch('grants')
        terms = Entitlements.for_account(@account)
        enabled = @account.active? && terms.dig('features', 'ai_reply') == true
        sources = %w[included grace]
        normal = grants.select { |grant| sources.include?(grant['source']) }
        { 'meter' => 'business_generation', 'period' => 'contract', 'enabled' => enabled,
          'used' => total(grants, 'used'), 'limit' => total(grants, 'limit'), 'reserved' => total(grants, 'reserved'),
          'remaining' => result.fetch('remaining'), 'resets_at' => normal.pluck('expires_at').min,
          'reason' => reason(enabled, result.fetch('remaining')), 'grants' => grants }.merge(ReplyPolicy.new(@account).automatic)
      end

      private

      def total(grants, key)
        grants.sum { |grant| grant.fetch(key) }
      end

      def reason(enabled, remaining)
        return 'account_inactive' unless @account.active?
        return 'disabled' unless enabled

        'limit_reached' if remaining.zero?
      end
    end
  end
end
