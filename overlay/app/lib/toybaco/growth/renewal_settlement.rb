# frozen_string_literal: true

require 'digest'
require_relative '../checkout'
require_relative '../checkout/plan_change_error'
require_relative '../checkout/plan_change_lock'
require_relative '../entitlements'
require_relative 'allowance'
require_relative 'renewal_payments'
require_relative 'renewal_invoice'
require_relative 'renewal_settlement_context'
require_relative 'renewal_transition'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # Provider settlement only. No scheduler/public entry point may call this
    # until Free access, connection holds and purchase locking are integrated.
    # A void is confirmed before cancellation so a concurrently paid invoice
    # preserves the subscription. Unknown provider results are read back.
    class RenewalSettlement
      include RenewalSettlementContext

      INACTIVE = %w[canceled incomplete_expired].freeze
      SETTLED = %w[paid void].freeze
      KEY = 'toybaco_growth_renewal_settlement'
      FAILURE_KEY = 'toybaco_growth_renewal_failure'
      class Unresolved < StandardError; end

      def initialize(account, client:, now: Time.now.utc, environment: ENV, **options)
        @account = account
        @client = client
        @now = now
        @environment = environment
        @synchronizer = options.fetch(:synchronizer, Checkout::PlanChangeLock)
        @inventory = options[:inventory]
        @transition = RenewalTransition.new(account, now: now, mode: environment.fetch('TOYBACO_STRIPE_MODE', 'live'))
      end

      def call
        @synchronizer.call(@account) do
          assert_commit_boundary!
          prepared = @account.with_lock { prepare_transition! }
          return prepared unless prepared == 'prepared'

          @account.with_lock do
            next 'not_due' unless due?
            next 'billing_operation_pending' unless billing_operations_finished?

            @transition.current!
            subscription!
            settle_invoice!
          end
        end
      rescue Checkout::PlanChangeError
        'billing_operation_pending'
      rescue Checkout::Error, RenewalPayments::Unresolved, RenewalProviderPages::Unresolved, Unresolved,
             RenewalTransition::Changed, RetentionPlan::Invalid, PlanCatalog::Invalid
        'retry_required'
      end

      private

      def assert_commit_boundary!
        return unless @account.class.respond_to?(:connection)

        raise Unresolved if @account.class.connection.transaction_open?
      end

      def inventory
        return @inventory if @inventory

        require_relative 'retention_inventory'
        @inventory = RetentionInventory.new(@account)
      end

      def prepare_transition!
        return 'not_due' unless due?
        return 'billing_operation_pending' unless billing_operations_finished?

        subscription!
        result = invoice_state(invoice!)
        return result if result

        @transition.prepare!(inventory: inventory)
        'prepared'
      end

      def settle_invoice!
        invoice = invoice!
        result = invoice_state(invoice)
        return result if result

        close_invoice!(invoice)
        finish_subscription!
      end

      def invoice_state(invoice)
        return paid! if invoice['status'] == 'paid'
        return 'review_required' unless %w[open void].include?(invoice['status']) && unpaid?(invoice)
        return 'other_debt' unless safe_customer?
        return 'payment_in_progress' if invoice['status'] == 'open' && !RenewalPayments.new(@client, invoice).idle?

        nil
      end

      def paid!
        @transition.advance!('payment_recovered') if Entitlements.attributes(@account).key?(RenewalTransition::KEY)
        'paid'
      end

      def unpaid?(invoice)
        invoice['amount_paid'].is_a?(Integer) && invoice['amount_paid'].zero?
      end

      def safe_customer?
        isolated_customer? && other_debts_absent?
      end

      def other_debts_absent?
        pages = RenewalProviderPages.new(prefix: 'in_') do |cursor|
          @client.list_customer_invoices(@customer_id, starting_after: cursor)
        end
        pages.each do |invoice|
          raise Unresolved unless invoice['customer'] == @customer_id && correct_mode?(invoice)
          return false unless invoice['id'] == @invoice_id || SETTLED.include?(invoice['status'])
        end
        true
      end

      def close_invoice!(invoice)
        return if invoice['status'] == 'void'
        raise Unresolved unless invoice['amount_remaining'].is_a?(Integer) && invoice['amount_remaining'].positive?

        key = Digest::SHA256.hexdigest([@account.id, @subscription_id, @invoice_id, @failure['first_failed_at']].join(':'))
        begin
          @client.void_invoice(@invoice_id, idempotency_key: "toybaco-renewal-void-#{key}")
        rescue Checkout::Error
          # A lost response may have committed. Never infer failure or retry a
          # mutation before reading its current authoritative result.
        end
      end

      def finish_subscription!
        invoice = invoice!
        return paid! if invoice['status'] == 'paid'
        return 'retry_required' unless invoice['status'] == 'void' && unpaid?(invoice)

        record_void!
        sub = subscription!
        return 'other_debt' unless safe_customer?

        cancel_subscription! unless sub['status'] == 'canceled'
        return 'retry_required' unless closure_confirmed?

        @transition.advance!('provider_closed')
        record!('closed')
        'closed'
      end

      def record_void!
        return if @transition.current!['state'] == 'provider_closed'

        @transition.advance!('invoice_voided')
        record!('invoice_voided')
      end

      def closure_confirmed?
        subscription!['status'] == 'canceled' && invoice!['status'] == 'void'
      end

      def isolated_customer?
        ids = @account.class.where("internal_attributes ->> 'toybaco_stripe_customer_id' = ?", @customer_id).limit(2).pluck(:id)
        return false unless ids == [@account.id]

        siblings_absent? && pending_items_absent?
      end

      def siblings_absent?
        pages = RenewalProviderPages.new(prefix: 'sub_') do |cursor|
          @client.list_customer_subscriptions(@customer_id, starting_after: cursor)
        end
        pages.each do |sub|
          raise Unresolved unless sub['customer'] == @customer_id && correct_mode?(sub)
          return false unless sub['id'] == @subscription_id || INACTIVE.include?(sub['status'])
        end
        true
      end

      def pending_items_absent?
        pending = @client.pending_customer_invoice_items(@customer_id)
        pending.is_a?(Hash) && pending['has_more'] == false && pending['data'] == []
      end

      def cancel_subscription!
        @client.cancel_unpaid_subscription(@subscription_id)
      rescue Checkout::Error
        # DELETE can have completed even when its response was lost.
        nil
      end

      def record!(state)
        receipt = { 'subscription_id' => @subscription_id, 'invoice_id' => @invoice_id,
                    'first_failed_at' => @failure['first_failed_at'], 'state' => state, 'observed_at' => @now.to_i }
        @account.update!(internal_attributes: Entitlements.attributes(@account).merge(KEY => receipt))
      end
    end
  end
end
