# frozen_string_literal: true

require_relative 'renewal_transition'
require_relative 'renewal_invoice'
require_relative 'renewal_grace'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # Called by PaidPeriod inside the account transaction, after fresh paid
    # coverage has been applied. A completed provider mutation is never undone.
    class RenewalRecovery
      def initialize(account, now:, environment: ENV)
        @account = account
        @now = now
        @mode = environment['TOYBACO_STRIPE_MODE']
      end

      def observe!(subscription, coverage)
        attrs = Entitlements.attributes(@account)
        receipt = attrs[RenewalTransition::KEY]
        return false unless RenewalTransition.valid?(receipt) && receipt['state'] == 'prepared'
        return false unless same_source?(receipt['binding'], attrs)
        return false unless paid_renewal?(subscription, coverage, receipt['binding'])

        recovered = receipt.merge('state' => 'payment_recovered', 'observed_at' => @now.to_i)
        @account.update!(internal_attributes: attrs.merge(RenewalTransition::KEY => recovered))
        true
      end

      private

      def same_source?(binding, attrs)
        failure = binding['failure']
        return false unless valid_failure?(failure) && %w[test live].include?(@mode)

        @account.active? && same_account?(binding, attrs) &&
          failure['subscription_id'] == binding['subscription_id'] && same_failure?(attrs, failure)
      end

      def same_account?(binding, attrs)
        binding['account_id'] == @account.id && binding['mode'] == @mode &&
          binding['source'] == Entitlements.contract_for(@account) &&
          binding['subscription_id'] == attrs['toybaco_subscription_id'] && binding['customer_id'] == attrs['toybaco_stripe_customer_id']
      end

      def same_failure?(attrs, failure)
        return true unless attrs.key?(RenewalGrace::FAILURE_KEY)

        current = attrs[RenewalGrace::FAILURE_KEY]
        current.is_a?(Hash) && current.slice(*RenewalTransition::FAILURE_FIELDS) == failure
      end

      def valid_failure?(failure)
        failure.is_a?(Hash) && %w[first_failed_at grace_ends_at term_start term_end].all? { |field| positive?(failure[field]) } &&
          failure['term_start'] <= failure['first_failed_at'] && failure['first_failed_at'] < failure['term_end'] &&
          failure['grace_ends_at'] == failure['first_failed_at'] + Allowance::GRACE_SECONDS
      end

      def paid_renewal?(subscription, coverage, binding)
        invoice = subscription['latest_invoice']
        failure = binding['failure']
        return false unless invoice.is_a?(Hash) && coverage.is_a?(Hash)

        same_provider?(subscription, invoice, binding) && same_invoice?(invoice, failure) &&
          current_coverage?(coverage, failure) && RenewalInvoice.new(invoice, binding['source'], failure).valid?
      end

      def same_invoice?(invoice, failure)
        invoice['id'] == failure['invoice_id'] && invoice['billing_reason'] == 'subscription_cycle' && paid_amount?(invoice)
      end

      def same_provider?(subscription, invoice, binding)
        subscription['id'] == binding['subscription_id'] && subscription['status'] == 'active' && subscription['pause_collection'].nil? &&
          [subscription, invoice].all? do |object|
            object['customer'] == binding['customer_id'] && object['livemode'] == (@mode == 'live') &&
              object['collection_method'] == 'charge_automatically'
          end
      end

      def paid_amount?(invoice)
        invoice['status'] == 'paid' && invoice['currency'] == 'jpy' &&
          invoice['amount_remaining'].is_a?(Integer) && invoice['amount_remaining'].zero? &&
          positive?(invoice['amount_due']) && invoice['amount_paid'] == invoice['amount_due']
      end

      def current_coverage?(coverage, failure)
        %w[subscription_id invoice_id term_start term_end].all? { |field| coverage[field] == failure[field] } &&
          positive?(coverage['paid_at']) && coverage['paid_at'].between?(failure['first_failed_at'], @now.to_i) &&
          @now.to_i >= failure['term_start'] && @now.to_i < failure['term_end']
      end

      def positive?(value)
        value.is_a?(Integer) && value.positive?
      end
    end
  end
end
