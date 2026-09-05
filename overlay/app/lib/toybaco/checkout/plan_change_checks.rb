# frozen_string_literal: true

require 'digest'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Checkout
    # Eligibility is deliberately narrower than contract synchronization. Historical
    # contracts remain valid even when they cannot use this self-service operation.
    module PlanChangeChecks
      private

      def reject!(code)
        raise PlanChangeError, code
      end

      def attrs
        Entitlements.attributes(@account)
      end

      def subscription
        id = attrs['toybaco_subscription_id']
        value = @client.retrieve_subscription(id)
        reject!('unavailable') unless value.is_a?(Hash) && value['id'] == id
        reject!('unsupported') unless value['livemode'] == (@environment.fetch('TOYBACO_STRIPE_MODE', 'live') == 'live')
        value
      end

      def contract
        Entitlements.contract_for(@account, catalog: @catalog) || reject!('unsupported')
      end

      def item_for(sub)
        reject!('unsupported') if sub.dig('items', 'has_more') == true
        items = sub.dig('items', 'data')
        reject!('unsupported') unless items.is_a?(Array) && items.length == 1 && items.first['quantity'] == 1
        item = items.first
        reject!('unsupported') unless item['id'].to_s.match?(/\Asi_[A-Za-z0-9]+\z/)
        item
      end

      def period(sub)
        item = item_for(sub)
        [item['current_period_start'] || sub['current_period_start'], item['current_period_end'] || sub['current_period_end']]
      end

      def eligible!(sub)
        saved = contract
        validate_saved!(saved)
        item = item_for(sub)
        reject!('unsupported') unless saved['stripe_price_id'] == item.dig('price', 'id')
        validate_status!(sub)
        validate_period!(sub)
        reject!('unsupported') if complex_billing?(sub, item)
        validate_source_price!(saved, item)
        saved
      end

      def validate_saved!(saved)
        return unless saved['legacy'] || saved.fetch('addons').any? || Array(attrs['toybaco_addons']).any? || attrs['toybaco_billing_review']

        reject!('unsupported')
      end

      def validate_status!(sub)
        reject!('payment_pending') if sub['pending_update']
        reject!('cancel_pending') if sub['cancel_at_period_end'] || sub['cancel_at']
        reject!('unpaid') unless sub['status'] == 'active' && sub.dig('latest_invoice', 'status') == 'paid'
        reject!('unsupported') unless sub['collection_method'] == 'charge_automatically'
      end

      def validate_period!(sub)
        start_at, end_at = period(sub)
        reject!('changed') unless start_at.is_a?(Integer) && end_at.is_a?(Integer) && start_at <= now && now < end_at
      end

      def validate_source_price!(saved, item)
        terms = @catalog.definition(saved.fetch('plan_id'), saved.fetch('plan_version'))
        Checkout.assert_checkout_price!(item.fetch('price'), terms, saved.fetch('cycle'), @environment)
        current = Resolver.price_for(terms, saved.fetch('cycle'), client: @client, environment: @environment)
        reject!('unsupported') unless current['id'] == item.dig('price', 'id')
      end

      def complex_billing?(sub, item)
        %w[discount discounts pause_collection pending_invoice_item_interval transfer_data application_fee_percent on_behalf_of
           billing_thresholds].any? do |key|
          present_value?(sub[key])
        end || %w[discounts billing_thresholds].any? { |key| present_value?(item[key]) } || present_value?(sub['billing_schedules'])
      end

      def present_value?(value)
        !value.nil? && value != false && value != [] && value != {}
      end

      def target_for(selection)
        terms = @catalog.sale(selection.fetch('plan_id'), selection.fetch('cycle'), version: selection.fetch('plan_version'))
        price = Resolver.price_for(terms, selection.fetch('cycle'), client: @client, environment: @environment)
        Checkout.assert_checkout_price!(price, terms, selection.fetch('cycle'), @environment)
        [terms, price]
      end

      def policy_for(saved, selection)
        @catalog.change_policy(from: saved, to: selection)
      end

      def now
        @clock.call.to_i
      end

      def schedule_id(sub)
        sub['schedule'].is_a?(Hash) ? sub['schedule']['id'] : sub['schedule']
      end

      def paid_target?(sub, receipt)
        !sub['pending_update'] && sub['status'] == 'active' && sub.dig('latest_invoice', 'status') == 'paid' &&
          item_for(sub).dig('price', 'id') == receipt.dig('quote', 'target_price')
      end
    end
  end
end
