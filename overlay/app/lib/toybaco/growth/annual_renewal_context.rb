# frozen_string_literal: true

require_relative 'paid_period'
require_relative '../entitlements'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # Only the currently paid annual term can establish a renewal notice.
    module AnnualRenewalContext
      private

      def eligible?
        @attrs = Entitlements.attributes(@account)
        @contract = Entitlements.contract_for(@account)
        @account.active? && annual_contract? && !@attrs['toybaco_billing_review'] && local_window?
      end

      def annual_contract?
        @contract && @contract['cycle'] == 'year' && @contract['legacy'] != true && @contract['plan_id'] != 'free' &&
          @contract['addons'] == [] && @contract.dig('entitlements', 'ai_meter') == GrowthTerms::METER
      end

      def local_window?
        paid = @attrs[PaidPeriod::KEY]
        return false unless paid.is_a?(Hash) && paid['subscription_id'] == @attrs['toybaco_subscription_id']

        same_terms = %w[plan_id plan_version cycle stripe_price_id].all? { |key| paid[key] == @contract[key] }
        return false unless paid['term_end'].is_a?(Integer) && same_terms

        paid['term_end'].between?(@now.to_i + 1, @now.to_i + (30 * 86_400))
      end

      def current_term(subscription)
        return unless subscription.is_a?(Hash) && current_subscription?(subscription)

        period = PaidCoverage.new(subscription, @contract).verified
        return unless period && paid_now?(period)

        remaining = period['term_end'] - @now.to_i
        return unless remaining.between?(1, 30 * 86_400)

        @deadline = period['term_end']
        @stage = remaining <= 7 * 86_400 ? 'seven_days' : 'thirty_days'
        @renewal = "#{subscription['id']}:#{@deadline}"
        true
      end

      def paid_now?(period)
        period['term_start'] <= @now.to_i && period['paid_at'] <= @now.to_i
      end

      def current_subscription?(subscription)
        matching_identity?(subscription) && continuing?(subscription) && annual_price?(subscription)
      end

      def matching_identity?(subscription)
        mode = ENV.fetch('TOYBACO_STRIPE_MODE', 'live')
        %w[test live].include?(mode) && subscription['livemode'] == (mode == 'live') &&
          subscription['id'] == @attrs['toybaco_subscription_id'] &&
          subscription['customer'] == @attrs['toybaco_stripe_customer_id'] &&
          @attrs['toybaco_stripe_customer_id'].to_s.match?(/\Acus_[A-Za-z0-9]+\z/)
      end

      def continuing?(subscription)
        subscription['collection_method'] == 'charge_automatically' && subscription['cancel_at_period_end'] == false &&
          subscription['cancel_at'].nil? && subscription['canceled_at'].nil? && subscription['pending_update'].nil? &&
          subscription['schedule'].nil? && subscription['pause_collection'].nil?
      end

      def annual_price?(subscription)
        items = subscription.dig('items', 'data')
        return false unless items.is_a?(Array) && items.one?

        price = items.first['price']
        price.is_a?(Hash) && price['currency'] == 'jpy' && price.dig('recurring', 'interval') == 'year' &&
          price.dig('recurring', 'interval_count') == 1
      end
    end
  end
end
