# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    module RenewalSettlementContext
      private

      def due?
        @attrs = Entitlements.attributes(@account)
        @failure = @attrs[RenewalSettlement::FAILURE_KEY]
        @contract = Entitlements.contract_for(@account)
        return false unless eligible_contract? && valid_deadline?

        @subscription_id = @failure['subscription_id']
        @invoice_id = @failure['invoice_id']
        @customer_id = @attrs['toybaco_stripe_customer_id']
        @subscription_id == @attrs['toybaco_subscription_id'] && @subscription_id.to_s.match?(/\Asub_[A-Za-z0-9]+\z/) &&
          @invoice_id.to_s.match?(/\Ain_[A-Za-z0-9]+\z/) && @customer_id.to_s.match?(/\Acus_[A-Za-z0-9]+\z/)
      end

      def eligible_contract?
        @contract && @contract['plan_id'] != 'free' && @contract['legacy'] != true && @contract['addons'] == [] &&
          @contract.dig('entitlements', 'ai_meter') == GrowthTerms::METER && !@attrs['toybaco_billing_review']
      end

      # A process may stop after saving an intent but before its Stripe request
      # returns. Taking the same lock alone cannot resolve that durable intent.
      def billing_operations_finished?
        terminal_receipt?('toybaco_plan_change', 'status', %w[applied released expired]) &&
          terminal_receipt?('toybaco_cancel_request', 'status', ['complete']) &&
          terminal_receipt?('toybaco_growth_purchase', 'state', %w[complete expired]) && pack_checkouts_finished?
      end

      def pack_checkouts_finished?
        return true unless defined?(Toybaco::GrowthPackOrder)

        !Toybaco::GrowthPackOrder.where(account_id: @account.id).where.not(state: %w[complete expired refunded]).exists?
      end

      def terminal_receipt?(key, state_key, terminal)
        return true unless @attrs.key?(key)

        receipt = @attrs[key]
        receipt.is_a?(Hash) && terminal.include?(receipt[state_key])
      end

      def valid_times?
        @failure.is_a?(Hash) && %w[first_failed_at grace_ends_at term_start term_end].all? { |key| @failure[key].is_a?(Integer) }
      end

      def valid_deadline?
        valid_times? &&
          @failure['term_start'].positive? && @failure['term_start'] <= @failure['first_failed_at'] &&
          @failure['first_failed_at'] < @failure['term_end'] &&
          @failure['grace_ends_at'] == @failure['first_failed_at'] + Allowance::GRACE_SECONDS && @now.to_i >= @failure['grace_ends_at']
      end

      def correct_mode?(object)
        mode = @environment.fetch('TOYBACO_STRIPE_MODE', 'live')
        %w[test live].include?(mode) && object['livemode'] == (mode == 'live')
      end

      def subscription!
        sub = @client.retrieve_subscription(@subscription_id)
        raise RenewalSettlement::Unresolved unless valid_subscription?(sub)

        sub
      end

      def subscription_identity?(sub)
        sub.is_a?(Hash) && sub['id'] == @subscription_id && sub['customer'] == @customer_id && correct_mode?(sub)
      end

      def valid_subscription?(sub)
        subscription_identity?(sub) &&
          %w[active past_due unpaid canceled].include?(sub['status']) && sub['collection_method'] == 'charge_automatically' &&
          !sub['pending_update'] && !sub['schedule'] && latest_id(sub) == @invoice_id && same_period?(sub)
      end

      def latest_id(sub)
        sub['latest_invoice'].is_a?(Hash) ? sub['latest_invoice']['id'] : sub['latest_invoice']
      end

      def one_item?(items)
        items.is_a?(Hash) && items['has_more'] == false && items['data'].is_a?(Array) && items['data'].one?
      end

      def matching_item?(item)
        item.is_a?(Hash) && item['price'].is_a?(Hash) && item['id'] == @contract['subscription_item_id'] &&
          item['quantity'] == 1 && item['price']['id'] == @contract['stripe_price_id']
      end

      def same_period?(sub)
        items = sub['items']
        return false unless one_item?(items)

        item = items['data'].first
        matching_item?(item) &&
          (item['current_period_start'] || sub['current_period_start']) == @failure['term_start'] &&
          (item['current_period_end'] || sub['current_period_end']) == @failure['term_end']
      end

      def invoice!
        invoice = @client.retrieve_invoice(@invoice_id)
        subscription = invoice.is_a?(Hash) && (invoice['subscription'] || invoice.dig('parent', 'subscription_details', 'subscription'))
        raise RenewalSettlement::Unresolved unless invoice_identity?(invoice, subscription) && invoice['billing_reason'] == 'subscription_cycle' &&
                                                   invoice['collection_method'] == 'charge_automatically'
        raise RenewalSettlement::Unresolved unless RenewalInvoice.new(invoice, @contract, @failure).valid?

        invoice
      end

      def invoice_identity?(invoice, subscription)
        invoice.is_a?(Hash) && invoice['id'] == @invoice_id && invoice['customer'] == @customer_id &&
          subscription == @subscription_id && correct_mode?(invoice) && invoice['currency'] == 'jpy'
      end
    end
  end
end
