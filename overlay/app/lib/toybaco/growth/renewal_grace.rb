# frozen_string_literal: true

require_relative '../entitlements'
require_relative 'monthly_window'
require_relative 'allowance'
require_relative 'ai_grants'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # Only a signed first failure following verified paid coverage can establish
    # this allowance. Reading the balance never starts or extends the seven days.
    class RenewalGrace
      FAILURE_KEY = 'toybaco_growth_renewal_failure'
      TERMS = %w[plan_id plan_version stripe_price_id cycle].freeze

      def initialize(account, now: Time.now.utc)
        @account = account
        @now = now
      end

      def active?
        state = context
        state && @now.to_i >= state['starts_at'] && @now.to_i < state['ends_at']
      end

      def expired?
        attrs = Entitlements.attributes(@account)
        failure = attrs[FAILURE_KEY]
        return false unless growth_paid?(Entitlements.contract_for(@account)) && valid_failure?(failure)
        return false unless attrs['toybaco_subscription_id'] == failure['subscription_id'] && @now.to_i >= failure['grace_ends_at']

        !resolved?(attrs[PaidPeriod::KEY], failure)
      end

      def refresh!
        @account.with_lock do
          return unless active?

          grants = Toybaco::GrowthAiGrant.where(account_id: @account.id, source_key: context['key'])
          return if grants.exists?(source: 'included')

          previous = grants.find_by(source: 'grace')
          return tighten!(previous) if previous

          AiGrants.new(@account).issue!(source: 'grace', source_key: context['key'], units: context['units'],
                                        starts_at: Time.at(context['starts_at']).utc, ends_at: Time.at(context['ends_at']).utc)
        end
      end

      def permits?(grant)
        active? && grant.source_key == context['key'] && grant.ends_at > @now
      end

      # Called only by PaidPeriod after freshly verified paid invoice coverage.
      # Keep the same row so both consumed and in-flight reservations count
      # against the full allowance instead of getting an extra, separate bucket.
      def self.promote!(account, key:, period:, limit:)
        grant = Toybaco::GrowthAiGrant.find_by(account_id: account.id, source: 'grace', source_key: key)
        return unless grant

        raise AiGrants::Conflict, 'paid allowance conflicts with renewal grace' if grant.revoked_at || grant.units > limit

        grant.update!(source: 'included', units: limit, starts_at: Time.at(period.fetch('starts_at')).utc,
                      ends_at: Time.at(period.fetch('ends_at')).utc)
        grant
      end

      private

      def context
        attrs = Entitlements.attributes(@account)
        contract = Entitlements.contract_for(@account)
        failure = attrs[FAILURE_KEY]
        paid = attrs[PaidPeriod::KEY]
        return unless eligible?(attrs, contract, failure, paid)

        period = allowance_period(failure, paid)
        return unless period && failure['first_failed_at'] < period['ends_at']

        { 'key' => "paid:#{failure['subscription_id']}:#{period['starts_at']}:base",
          'starts_at' => failure['first_failed_at'], 'ends_at' => [failure['grace_ends_at'], period['ends_at']].min,
          'units' => Allowance.grace(limit: paid['normal_limit'], period_seconds: period['ends_at'] - period['starts_at']) }
      end

      def eligible?(attrs, contract, failure, paid)
        growth_paid?(contract) && valid_failure?(failure) && valid_paid?(paid) && same_terms?(contract, paid) &&
          follows_paid_period?(attrs, failure, paid)
      end

      def growth_paid?(contract)
        @account.active? && contract && contract['plan_id'] != 'free' && contract.dig('entitlements', 'ai_meter') == GrowthTerms::METER
      end

      def same_terms?(contract, paid)
        TERMS.all? { |key| contract[key] == paid[key] } && contract.dig('entitlements', 'limits', 'ai_generations') == paid['normal_limit']
      end

      def follows_paid_period?(attrs, failure, paid)
        attrs['toybaco_subscription_id'] == failure['subscription_id'] && paid['subscription_id'] == failure['subscription_id'] &&
          paid['term_end'] == failure['term_start'] && paid['paid_at'] < failure['term_start']
      end

      def valid_failure?(failure)
        failure.is_a?(Hash) && positive_times?(failure, %w[term_start term_end first_failed_at grace_ends_at]) &&
          failure['term_start'] <= failure['first_failed_at'] && failure['first_failed_at'] < failure['term_end'] &&
          failure['grace_ends_at'] == failure['first_failed_at'] + Allowance::GRACE_SECONDS
      end

      def valid_paid?(paid)
        paid.is_a?(Hash) && %w[month year].include?(paid['cycle']) && positive_times?(paid, %w[paid_at term_start term_end anchor]) &&
          paid['term_start'] < paid['term_end'] && paid['anchor'] <= paid['term_start'] &&
          paid['normal_limit'].is_a?(Integer) && paid['normal_limit'].positive?
      end

      def resolved?(paid, failure)
        valid_paid?(paid) && paid['subscription_id'] == failure['subscription_id'] &&
          paid['paid_at'].between?(failure['first_failed_at'], @now.to_i) && paid['term_start'] >= failure['term_start'] &&
          paid['term_end'] > failure['term_start']
      end

      def positive_times?(data, keys)
        keys.all? { |key| data[key].is_a?(Integer) && data[key].positive? }
      end

      def allowance_period(failure, paid)
        return { 'starts_at' => failure['term_start'], 'ends_at' => failure['term_end'] } if paid['cycle'] == 'month'

        MonthlyWindow.new(anchor: Time.at(paid['anchor']).utc, now: Time.at(failure['term_start']).utc,
                          ends_at: Time.at(failure['term_end']).utc).current
      end

      def tighten!(grant)
        return if grant.revoked_at

        # A late delivery of an earlier first-attempt event may shorten grace;
        # it may never replace the bucket, clear usage or increase its amount.
        ends_at = [grant.ends_at, Time.at(context['ends_at']).utc].min
        starts_at = [grant.starts_at, Time.at(context['starts_at']).utc].min
        grant.update!(starts_at: starts_at, ends_at: ends_at) if starts_at != grant.starts_at || ends_at != grant.ends_at
        grant
      end
    end
  end
end
