# frozen_string_literal: true

require_relative '../entitlements'
require_relative 'paid_period'
require_relative 'payment_signature'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # Capture the signed first-attempt timestamp before granting any renewal grace.
    # Processing time, card changes and later retries must never restart the clock.
    class RenewalFailureReceipt
      KEY = 'toybaco_growth_renewal_failure'
      SECONDS = 7 * 24 * 60 * 60
      class Unresolved < StandardError; end

      def initialize(receipt, client:, now: Time.now.utc)
        @receipt = receipt
        @client = client
        @now = now
        @invoice = receipt.snapshot.fetch('data').fetch('object')
      end

      def record!
        accounts = Account.where("internal_attributes ->> 'toybaco_subscription_id' = ?", @invoice.fetch('subscription')).limit(2).to_a
        raise Unresolved unless accounts.one?

        accounts.first.with_lock { record_for!(accounts.first) }
      end

      private

      def record_for!(account)
        attrs = Entitlements.attributes(account)
        raise Unresolved unless attrs['toybaco_subscription_id'] == @invoice['subscription']

        contract = Entitlements.contract_for(account)
        return 'outside_growth_terms' unless contract.dig('entitlements', 'ai_meter') == GrowthTerms::METER && contract['plan_id'] != 'free'

        subscription = retrieve_subscription
        verify_subscription!(subscription, attrs)
        latest = subscription['latest_invoice']
        return 'invoice_already_resolved' unless current_unpaid_invoice?(latest)
        return 'awaiting_first_failure' unless @invoice['attempt_count'] == 1

        save_first!(account, attrs, subscription, contract)
      end

      def retrieve_subscription
        @client.retrieve_subscription(@invoice.fetch('subscription'))
      end

      def verify_subscription!(subscription, attrs)
        valid = subscription.is_a?(Hash) && subscription['id'] == @invoice['subscription'] && correct_mode?(subscription) &&
                subscription['customer'] == @invoice['customer'] && attrs['toybaco_stripe_customer_id'] == @invoice['customer']
        raise PaymentSignature::Invalid unless valid
      end

      def correct_mode?(subscription)
        mode = ENV.fetch('TOYBACO_STRIPE_MODE', 'live')
        %w[test live].include?(mode) && subscription['livemode'] == (mode == 'live') &&
          @receipt.snapshot['livemode'] == subscription['livemode']
      end

      def current_unpaid_invoice?(latest)
        raise Unresolved unless latest.is_a?(Hash)
        return false if latest['id'] != @invoice['id'] || %w[paid void uncollectible].include?(latest['status'])

        subscription = latest['subscription'] || latest.dig('parent', 'subscription_details', 'subscription')
        raise PaymentSignature::Invalid unless valid_open_invoice?(latest) && subscription == @invoice['subscription']

        true
      end

      def valid_open_invoice?(latest)
        latest['status'] == 'open' && latest['billing_reason'] == 'subscription_cycle' && latest['currency'] == 'jpy' &&
          latest['amount_remaining'].is_a?(Integer) && latest['amount_remaining'].positive?
      end

      def save_first!(account, attrs, subscription, contract)
        identity = current_period(subscription, contract)
        created = @receipt.snapshot.fetch('created')
        previous = attrs[KEY]
        if continuing_failure?(previous, identity, attrs, created) && previous.fetch('first_failed_at') <= created
          return 'first_failure_already_recorded'
        end

        record = identity.merge('invoice_id' => @invoice['id'], 'event_id' => @receipt.event_id,
                                'first_failed_at' => created, 'grace_ends_at' => created + SECONDS)
        account.update!(internal_attributes: attrs.merge(KEY => record))
        'first_failure_recorded'
      end

      def continuing_failure?(previous, identity, attrs, created)
        return false unless previous.is_a?(Hash) && previous['subscription_id'] == identity['subscription_id']
        return true if previous['term_start'] == identity['term_start']

        # Merely advancing a past-due subscription into another month is not payment.
        !paid_between?(attrs[PaidPeriod::KEY], previous, identity, created)
      end

      def paid_between?(paid, previous, identity, created)
        return false unless valid_paid_record?(paid, identity)

        paid['paid_at'].between?(previous.fetch('first_failed_at'), created) && paid['term_start'] >= previous.fetch('term_start') &&
          paid['term_end'] > paid['term_start'] && paid['term_end'] <= identity.fetch('term_start')
      end

      def valid_paid_record?(paid, identity)
        paid.is_a?(Hash) && paid['subscription_id'] == identity['subscription_id'] &&
          %w[paid_at term_start term_end].all? { |key| paid[key].is_a?(Integer) }
      end

      def current_period(subscription, contract)
        item = current_item(subscription, contract)
        starts_at = item['current_period_start'] || subscription['current_period_start']
        ends_at = item['current_period_end'] || subscription['current_period_end']
        created = @receipt.snapshot.fetch('created')
        raise PaymentSignature::Invalid unless valid_period?(starts_at, ends_at, created)

        { 'subscription_id' => subscription['id'], 'term_start' => starts_at, 'term_end' => ends_at }
      end

      def valid_period?(starts_at, ends_at, created)
        [starts_at, ends_at, created].all? { |value| value.is_a?(Integer) && value.positive? } &&
          starts_at < ends_at && created.between?(starts_at, @now.to_i)
      end

      def complete_items?(items)
        items.is_a?(Hash) && items['has_more'] == false && items['data'].is_a?(Array)
      end

      def current_item(subscription, contract)
        items = subscription['items']
        raise Unresolved unless complete_items?(items)

        found = items['data'].select { |item| item['id'] == contract['subscription_item_id'] }
        item = found.first
        raise PaymentSignature::Invalid unless found.one? && item['quantity'] == 1 && item.dig('price', 'id') == contract['stripe_price_id']

        item
      end
    end
  end
end
