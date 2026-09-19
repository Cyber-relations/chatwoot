# frozen_string_literal: true

require_relative 'paid_coverage'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # New paid rights require the invoice that covers the changed base item.
    # A subscription can remain active while its newest invoice is unpaid.
    class PaidTransition
      TERMS = %w[plan_id plan_version cycle stripe_price_id subscription_item_id entitlements addons].freeze

      def self.allowed?(subscription, contract, previous, now: Time.now.utc)
        new(subscription, contract, previous, now).allowed?
      end

      def initialize(subscription, contract, previous, now)
        @subscription = subscription
        @contract = contract
        @previous = previous
        @now = now
      end

      def allowed?
        return true unless growth_paid?
        return true if unchanged?

        coverage = PaidCoverage.new(@subscription, @contract).verified
        coverage && current_payment?(coverage)
      end

      private

      def growth_paid?
        @contract['plan_id'] != 'free' && @contract.dig('entitlements', 'ai_meter') == GrowthTerms::METER
      end

      def unchanged?
        @previous && TERMS.all? { |key| @previous[key] == @contract[key] }
      end

      def current_payment?(coverage)
        coverage['paid_at'] <= @now.to_i && coverage['term_start'] <= @now.to_i && coverage['term_end'] > @now.to_i
      end
    end
  end
end
