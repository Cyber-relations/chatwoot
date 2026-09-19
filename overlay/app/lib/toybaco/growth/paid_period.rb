# frozen_string_literal: true

require_relative '../entitlements'
require_relative 'monthly_window'
require_relative 'ai_grants'
require_relative 'allowance'
require_relative 'paid_coverage'
require_relative 'trial_lifecycle'
require_relative 'renewal_grace'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class PaidPeriod
      KEY = 'toybaco_growth_paid_period'

      def initialize(account, now: Time.now.utc)
        @account = account
        @now = now
      end

      def observe!(subscription)
        @account.with_lock do
          contract = Entitlements.contract_for(@account)
          return unless growth_paid?(contract)

          coverage = PaidCoverage.new(subscription, contract).verified
          return unless coverage && matches_contract?(coverage, contract)

          apply_coverage!(coverage)
        end
      end

      def refresh!
        @account.with_lock do
          coverage = Entitlements.attributes(@account)[KEY]
          return unless coverage && matches_contract?(coverage, Entitlements.contract_for(@account))

          period = current(coverage)
          return unless period

          issue_base!(coverage, period, base_limit(coverage, period))
        end
      end

      private

      def growth_paid?(contract)
        @account.active? && contract && contract['plan_id'] != 'free' && contract.dig('entitlements', 'ai_meter') == GrowthTerms::METER
      end

      def matches_contract?(coverage, contract)
        growth_paid?(contract) && coverage['subscription_id'] == Entitlements.attributes(@account)['toybaco_subscription_id'] &&
          %w[plan_id plan_version stripe_price_id cycle].all? { |key| coverage[key] == contract[key] }
      end

      def current(coverage)
        return unless @now.to_i >= coverage.fetch('term_start') && @now.to_i < coverage.fetch('term_end')
        return { 'starts_at' => coverage['term_start'], 'ends_at' => coverage['term_end'] } if coverage['cycle'] == 'month'

        MonthlyWindow.new(anchor: Time.at(coverage.fetch('anchor')).utc, now: @now, ends_at: Time.at(coverage.fetch('term_end')).utc).current
      end

      def base_limit(coverage, period)
        coverage['current_period_start'] == period['starts_at'] ? coverage.fetch('current_base_limit') : coverage.fetch('normal_limit')
      end

      def apply_coverage!(coverage)
        period = current(coverage)
        return unless period && coverage['paid_at'] <= @now.to_i

        previous = previous_coverage(coverage, period)
        limit = previous ? base_limit(previous, period) : coverage.fetch('normal_limit')
        issue_base!(coverage, period, limit)
        issue_upgrade!(coverage, previous, period) if previous && coverage['normal_limit'] > previous['normal_limit']
        finish_free_allowance!
        saved = coverage.merge('current_period_start' => period['starts_at'], 'current_base_limit' => limit)
        @account.update!(internal_attributes: Entitlements.attributes(@account).merge(KEY => saved))
        TrialLifecycle.new(@account, now: @now).refresh!
      end

      def finish_free_allowance!
        Toybaco::GrowthAiGrant.where(account_id: @account.id, source: 'included', revoked_at: nil)
                              .where('left(source_key, 5) = ?', 'free:').find_each { |grant| grant.update!(revoked_at: @now) }
      end

      def previous_coverage(coverage, period)
        previous = Entitlements.attributes(@account)[KEY]
        return unless previous && previous['subscription_id'] == coverage['subscription_id'] && previous['cycle'] == coverage['cycle']
        return unless previous['term_start'] <= period['starts_at'] && previous['term_end'] >= period['ends_at']

        previous
      end

      def prefix(coverage, period)
        "paid:#{coverage.fetch('subscription_id')}:#{period.fetch('starts_at')}:"
      end

      def issue_base!(coverage, period, limit)
        key = "#{prefix(coverage, period)}base"
        RenewalGrace.promote!(@account, key: key, period: period, limit: limit)
        issue!(key, period, limit)
      end

      def issue_upgrade!(coverage, previous, period)
        key = "#{prefix(coverage, period)}upgrade:#{coverage.fetch('invoice_id')}"
        return if Toybaco::GrowthAiGrant.exists?(account_id: @account.id, source: 'included', source_key: key)

        amount = upgrade_amount(coverage, previous, period)
        issue!(key, period, amount) if amount.positive?
      end

      def upgrade_amount(coverage, previous, period)
        key_prefix = prefix(coverage, period)
        granted = Toybaco::GrowthAiGrant.where(account_id: @account.id, source: 'included')
                                        .where('left(source_key, ?) = ?', key_prefix.length, key_prefix).sum(:units)
        remaining = [period['ends_at'] - [coverage['paid_at'], period['starts_at']].max, 0].max
        Allowance.upgrade(old_limit: previous.fetch('normal_limit'), new_limit: coverage.fetch('normal_limit'), granted: granted,
                          period_seconds: period['ends_at'] - period['starts_at'], remaining_seconds: remaining)
      end

      def issue!(key, period, limit)
        AiGrants.new(@account).issue!(source: 'included', source_key: key, units: limit,
                                      starts_at: Time.at(period.fetch('starts_at')).utc, ends_at: Time.at(period.fetch('ends_at')).utc)
      end
    end
  end
end
