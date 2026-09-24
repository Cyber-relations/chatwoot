# frozen_string_literal: true

require 'minitest/autorun'
require 'monitor'
require_relative '../overlay/app/lib/toybaco/growth/renewal_settlement'
require_relative '../overlay/app/lib/toybaco/growth/renewal_recovery'
require_relative '../overlay/app/lib/toybaco/growth/paid_coverage'

class ToybacoGrowthRenewalSettlementTest < Minitest::Test
  NOW = Time.utc(2026, 10, 11, 12)
  SERVICE = Toybaco::Growth::RenewalSettlement

  class Account
    attr_accessor :internal_attributes
    attr_reader :id, :lock
    class << self
      attr_accessor :ids
      def where(*) = self
      def limit(*) = self
      def pluck(*) = ids
    end
    def initialize(attrs)
      @id, @internal_attributes, @lock = 41, attrs, Monitor.new
      self.class.ids = [id]
    end
    def with_lock(&block) = lock.synchronize(&block)
    def update!(internal_attributes:) = @internal_attributes = internal_attributes
    def active? = true
  end

  class Client
    attr_accessor :sub, :invoice, :payments, :intents, :debts, :siblings, :pending, :void_action, :cancel_action, :pages
    attr_reader :calls
    def initialize(account, subscription, invoice)
      @account, @sub, @invoice = account, subscription, invoice
      @payments, @intents, @debts, @siblings, @pending, @calls = [], {}, [], [], [], []
      @pages = nil
    end
    def copy(v) = Marshal.load(Marshal.dump(v))
    def retrieve_subscription(id)
      raise 'read outside lock' unless @account.lock.mon_owned?
      raise 'wrong subscription' unless id == 'sub_renewal'
      copy(sub)
    end
    def retrieve_invoice(id)
      raise 'wrong invoice' unless id == 'in_renewal'
      copy(invoice)
    end
    def list_invoice_payments(_id, starting_after: nil)
      return copy(pages.fetch(starting_after)) if pages
      { 'data' => copy(payments), 'has_more' => false }
    end
    def retrieve_payment_intent(id) = copy(intents.fetch(id))
    def list_customer_invoices(_id, starting_after: nil) = { 'data' => copy([invoice] + debts), 'has_more' => false }
    def list_customer_subscriptions(_id, starting_after: nil) = { 'data' => copy([sub] + siblings), 'has_more' => false }
    def pending_customer_invoice_items(_id) = { 'data' => copy(pending), 'has_more' => false }
    def void_invoice(id, idempotency_key:)
      @calls << [:void, id, idempotency_key]
      return void_action.call(self) if void_action
      invoice['status'] = 'void'
      copy(invoice)
    end
    def cancel_unpaid_subscription(id)
      @calls << [:cancel, id]
      return cancel_action.call(self) if cancel_action
      sub['status'] = 'canceled'
      copy(sub)
    end
  end

  def setup
    start_at = Time.utc(2026, 10, 3, 12).to_i
    end_at = Time.utc(2026, 11, 3, 12).to_i
    terms = Toybaco::PlanCatalog.default.definition('standard', '2026-09-18.1')
    contract = Toybaco::Entitlements.snapshot_for(terms, cycle: 'month').merge('stripe_price_id' => 'price_standard', 'subscription_item_id' => 'si_renewal')
    @account = Account.new({ 'toybaco_contract' => contract, 'toybaco_subscription_id' => 'sub_renewal', 'toybaco_stripe_customer_id' => 'cus_store',
                            SERVICE::FAILURE_KEY => { 'subscription_id' => 'sub_renewal', 'invoice_id' => 'in_renewal', 'term_start' => start_at,
                              'term_end' => end_at, 'first_failed_at' => start_at, 'grace_ends_at' => start_at + 604800 }, 'unrelated' => 'preserve' })
    invoice = { 'id' => 'in_renewal', 'customer' => 'cus_store', 'livemode' => false, 'currency' => 'jpy', 'subscription' => 'sub_renewal',
                'status' => 'open', 'amount_paid' => 0, 'amount_remaining' => 19800, 'billing_reason' => 'subscription_cycle', 'collection_method' => 'charge_automatically' }
    line = { 'id' => 'il_renewal', 'currency' => 'jpy', 'quantity' => 1, 'amount' => 19800,
      'parent' => { 'type' => 'subscription_item_details', 'subscription_item_details' => {
        'subscription' => 'sub_renewal', 'subscription_item' => 'si_renewal', 'proration' => false } },
      'pricing' => { 'price_details' => { 'price' => 'price_standard' } }, 'period' => { 'start' => start_at, 'end' => end_at } }
    invoice.merge!('starting_balance' => 0, 'amount_shipping' => 0, 'pre_payment_credit_notes_amount' => 0,
      'post_payment_credit_notes_amount' => 0, 'subtotal' => 19800, 'lines' => { 'data' => [line], 'has_more' => false })
    sub = { 'id' => 'sub_renewal', 'customer' => 'cus_store', 'livemode' => false, 'status' => 'past_due', 'collection_method' => 'charge_automatically',
            'latest_invoice' => { 'id' => 'in_renewal' }, 'items' => { 'has_more' => false, 'data' => [{ 'id' => 'si_renewal', 'quantity' => 1,
              'current_period_start' => start_at, 'current_period_end' => end_at, 'price' => { 'id' => 'price_standard' } }] } }
    @client = Client.new(@account, sub, invoice)
    @rows = { 'inboxes' => [{ 'id' => '1', 'name' => 'private display', 'created_at_us' => 1 },
                            { 'id' => '2', 'name' => 'second display', 'created_at_us' => 2 }],
              'posting_accounts' => [], 'posts' => [] }
    @inventory = Struct.new(:rows) { def read = Marshal.load(Marshal.dump(rows)) }.new(@rows)
    payment('pi_idle', 'requires_payment_method')
  end

  def run_service(now: NOW, mode: 'test')
    lock = ->(_account, &block) { block.call }
    SERVICE.new(@account, client: @client, now: now, environment: { 'TOYBACO_STRIPE_MODE' => mode }, synchronizer: lock, inventory: @inventory).call
  end

  def prepare_payment_recovery
    Toybaco::Growth::RenewalTransition.new(@account, now: NOW, mode: 'test').prepare!(inventory: @inventory)
    invoice = @client.copy(@client.invoice)
    invoice.merge!('status' => 'paid', 'amount_due' => 19800, 'amount_paid' => 19800, 'amount_remaining' => 0,
      'status_transitions' => { 'paid_at' => NOW.to_i })
    @client.copy(@client.sub).merge('status' => 'active', 'latest_invoice' => invoice,
      'billing_cycle_anchor' => invoice.dig('lines', 'data', 0, 'period', 'start'))
  end

  def recover(subscription, mode: 'test')
    coverage = Toybaco::Growth::PaidCoverage.new(subscription, Toybaco::Entitlements.contract_for(@account)).verified
    Toybaco::Growth::RenewalRecovery.new(@account, now: NOW, environment: { 'TOYBACO_STRIPE_MODE' => mode }).observe!(subscription, coverage)
  end

  def test_fresh_paid_subscription_releases_prepared_transition_even_without_failure_attribute
    subscription = prepare_payment_recovery
    journal = Toybaco::Growth::RenewalTransition
    saved = @client.copy(@account.internal_attributes[journal::KEY])
    @account.internal_attributes.delete(SERVICE::FAILURE_KEY)
    assert recover(subscription)
    assert_equal 'payment_recovered', @account.internal_attributes.dig(journal::KEY, 'state')
    assert_equal saved['id'], @account.internal_attributes.dig(journal::KEY, 'id')
    refute journal.pending?(@account)
    refute recover(subscription)
    assert_empty @client.calls
  end

  def test_recovery_rejects_unrelated_or_incomplete_payment_proof
    original = prepare_payment_recovery
    journal = Toybaco::Growth::RenewalTransition
    saved = @client.copy(@account.internal_attributes[journal::KEY])
    changes = [
      ->(sub) { sub['customer'] = 'cus_other' },
      ->(sub) { sub['latest_invoice']['id'] = 'in_other' },
      ->(sub) { sub['latest_invoice']['livemode'] = true },
      ->(sub) { sub['latest_invoice']['amount_paid'] = 1 },
      ->(sub) { sub['latest_invoice']['amount_due'] = nil },
      ->(sub) { sub['latest_invoice']['status_transitions']['paid_at'] = NOW.to_i + 1 },
      ->(sub) { sub['latest_invoice']['lines']['data'].first['parent']['subscription_item_details']['proration'] = true }
    ]
    changes.each do |change|
      sub = @client.copy(original)
      change.call(sub)
      refute recover(sub)
      assert_equal saved, @account.internal_attributes[journal::KEY]
    end
    refute recover(original, mode: 'live')
    assert journal.pending?(@account)
  end

  def test_paid_proof_never_undoes_voided_or_closed_provider_state
    subscription = prepare_payment_recovery
    journal = Toybaco::Growth::RenewalTransition
    %w[invoice_voided provider_closed].each do |state|
      @account.internal_attributes[journal::KEY]['state'] = state
      refute recover(subscription)
      assert journal.pending?(@account)
    end
  end

  def test_fully_paid_tax_inclusive_total_recovers_without_reinterpreting_the_base_price
    subscription = prepare_payment_recovery
    subscription['latest_invoice'].merge!('amount_due' => 21780, 'amount_paid' => 21780)
    assert recover(subscription)
    refute Toybaco::Growth::RenewalTransition.pending?(@account)
  end

  def test_changed_contract_keeps_prepared_transition_fenced
    subscription = prepare_payment_recovery
    terms = Toybaco::PlanCatalog.default.definition('free', '2026-09-18.1')
    @account.internal_attributes['toybaco_contract'] = Toybaco::Entitlements.snapshot_for(terms, cycle: nil)
    refute recover(subscription)
    assert Toybaco::Growth::RenewalTransition.pending?(@account)
  end

  def test_pending_billing_receipts_block_provider_mutations_even_after_process_lock_is_released
    { 'toybaco_plan_change' => ['status', %w[requested payment_pending reserved releasing unknown]],
      'toybaco_cancel_request' => ['status', %w[requested unknown]],
      'toybaco_growth_purchase' => ['state', %w[prepared open payment_pending unknown]] }.each do |key, (state_key, states)|
      states.each do |state|
        @account.internal_attributes[key] = { state_key => state }
        assert_equal 'billing_operation_pending', run_service
        assert_empty @client.calls
      end
      [nil, true, 'complete', {}].each do |invalid|
        @account.internal_attributes[key] = invalid
        assert_equal 'billing_operation_pending', run_service
      end
      @account.internal_attributes.delete(key)
    end
  end

  def test_terminal_receipts_allow_settlement_without_reopening_old_operations
    @account.internal_attributes.merge!(
      'toybaco_plan_change' => { 'status' => 'released' },
      'toybaco_cancel_request' => { 'status' => 'complete' },
      'toybaco_growth_purchase' => { 'state' => 'complete' }
    )
    before = Marshal.dump(@account.internal_attributes.slice('toybaco_plan_change', 'toybaco_cancel_request', 'toybaco_growth_purchase'))
    assert_equal 'closed', run_service
    assert_equal before, Marshal.dump(@account.internal_attributes.slice('toybaco_plan_change', 'toybaco_cancel_request', 'toybaco_growth_purchase'))
  end

  def test_another_billing_operation_holds_the_shared_lock
    lock = ->(_account) { raise Toybaco::Checkout::PlanChangeError, 'busy' }
    result = SERVICE.new(@account, client: @client, now: NOW, synchronizer: lock).call
    assert_equal 'billing_operation_pending', result
    assert_empty @client.calls
  end

  def test_manual_charge_on_the_same_invoice_is_never_voided
    @client.invoice['lines']['data'] << { 'id' => 'il_manual', 'amount' => 100 }
    assert_equal 'retry_required', run_service
    assert_empty @client.calls
  end

  def test_previous_balance_shipping_and_credit_notes_are_not_canceled_with_the_renewal
    Toybaco::Growth::RenewalInvoice::ZERO_FIELDS.each do |field|
      [100, -100, nil].each do |value|
        @client.invoice[field] = value
        assert_equal 'retry_required', run_service
        assert_empty @client.calls
      end
      @client.invoice[field] = 0
    end
  end

  def test_truncated_line_list_never_authorizes_void
    @client.invoice['lines']['has_more'] = true
    assert_equal 'retry_required', run_service
    assert_empty @client.calls
  end

  def test_line_period_price_and_proration_must_match_the_failed_renewal
    line = @client.invoice['lines']['data'].first
    original = Marshal.dump(line)
    changes = [
      ->(row) { row['period']['start'] += 1 },
      ->(row) { row['pricing']['price_details']['price'] = 'price_other' },
      ->(row) { row['parent']['subscription_item_details']['proration'] = true },
      ->(row) { row['parent']['subscription_item_details']['subscription_item'] = 'si_other' },
      ->(row) { row['amount'] = 1 },
      ->(row) { row['quantity'] = 2 },
      ->(row) { row['currency'] = 'usd' }
    ]
    changes.each do |change|
      row = Marshal.load(original)
      change.call(row)
      @client.invoice['lines']['data'] = [row]
      assert_equal 'retry_required', run_service
      assert_empty @client.calls
    end
  end

  def test_legacy_invoice_line_shape_is_verified_with_the_same_period_and_price
    line = @client.invoice['lines']['data'].first
    line.delete('parent')
    line.delete('pricing')
    line.merge!('type' => 'subscription', 'subscription' => 'sub_renewal', 'subscription_item' => 'si_renewal',
      'proration' => false, 'price' => { 'id' => 'price_standard' })
    assert_equal 'closed', run_service
  end

  def test_modified_line_after_void_prevents_subscription_cancellation
    @client.void_action = lambda do |client|
      client.invoice['status'] = 'void'
      client.invoice['lines']['data'] << { 'id' => 'il_other' }
    end
    assert_equal 'retry_required', run_service
    assert_equal [:void], @client.calls.map(&:first)
  end

  def test_prepared_choice_survives_unexpected_provider_failure_and_retry_does_not_reselect
    snapshot = Toybaco::Growth::RetentionSnapshot.new(@account, target: 'free', rows: @rows).read
    @account.internal_attributes[Toybaco::Growth::RetentionSnapshot::KEY] = {
      'context' => snapshot.fetch('context'), 'selected' => { 'inboxes' => ['2'], 'posting_accounts' => [] }
    }
    @client.void_action = lambda do |client|
      client.invoice['status'] = 'void'
      raise 'simulated process failure after provider write'
    end
    assert_raises(RuntimeError) { run_service }
    journal = @account.internal_attributes.fetch(Toybaco::Growth::RenewalTransition::KEY)
    assert_equal 'prepared', journal['state']
    assert_equal ['2'], journal.dig('retention', 'plan', 'inboxes', 'keep')
    refute_includes JSON.generate(journal), 'private display'
    @rows['inboxes'].clear
    @client.void_action = nil
    assert_equal 'closed', run_service
    saved = @account.internal_attributes.fetch(Toybaco::Growth::RenewalTransition::KEY)
    assert_equal journal['id'], saved['id']
    assert_equal ['2'], saved.dig('retention', 'plan', 'inboxes', 'keep')
    assert_equal 'provider_closed', saved['state']
    assert Toybaco::Growth::RenewalTransition.pending?(@account)
  end

  def test_changed_contract_after_preparation_stops_retry_before_another_provider_mutation
    @client.void_action = ->(_client) { raise 'simulated crash' }
    assert_raises(RuntimeError) { run_service }
    @account.internal_attributes['toybaco_contract']['name'] = 'different terms'
    @client.void_action = nil
    assert_equal 'retry_required', run_service
    assert_equal [:void], @client.calls.map(&:first)
  end

  def test_incomplete_inventory_stops_before_invoice_void
    @inventory.define_singleton_method(:read) { raise Toybaco::Growth::RetentionPlan::Invalid }
    assert_equal 'retry_required', run_service
    assert_empty @client.calls
    refute @account.internal_attributes.key?(Toybaco::Growth::RenewalTransition::KEY)
  end

  def test_paid_race_releases_preparation_without_granting_free_or_issuing_new_ai
    original = Marshal.dump(@account.internal_attributes['toybaco_contract'])
    @client.void_action = lambda do |client|
      client.invoice['status'] = 'paid'
      client.invoice['amount_paid'] = 19800
      raise Toybaco::Checkout::Error, 'already paid'
    end
    assert_equal 'paid', run_service
    assert_equal 'payment_recovered', @account.internal_attributes.dig(Toybaco::Growth::RenewalTransition::KEY, 'state')
    refute Toybaco::Growth::RenewalTransition.pending?(@account)
    assert_equal original, Marshal.dump(@account.internal_attributes['toybaco_contract'])
    assert_equal [:void], @client.calls.map(&:first)
  end

  def test_corrupt_or_foreign_transition_is_not_replaced_or_completed
    @account.internal_attributes[Toybaco::Growth::RenewalTransition::KEY] = { 'state' => 'provider_closed' }
    assert_equal 'retry_required', run_service
    assert_empty @client.calls
    assert Toybaco::Growth::RenewalTransition.pending?(@account)
  end

  def payment(id, status)
    @client.payments << { 'id' => "inpay_#{id.delete('_')}", 'invoice' => 'in_renewal', 'livemode' => false, 'currency' => 'jpy', 'status' => 'open',
                          'payment' => { 'type' => 'payment_intent', 'payment_intent' => id } }
    @client.intents[id] = { 'id' => id, 'customer' => 'cus_store', 'livemode' => false, 'currency' => 'jpy', 'status' => status, 'amount_received' => 0 }
  end

  def test_closes_only_exact_unpaid_renewal_and_retries_without_more_mutations
    before = Marshal.dump(@account.internal_attributes['toybaco_contract'])
    3.times { assert_equal 'closed', run_service }
    assert_equal [:void, :cancel], @client.calls.map(&:first)
    assert_equal 'in_renewal', @client.calls.first[1]
    assert_match(/\Atoybaco-renewal-void-[a-f0-9]{64}\z/, @client.calls.first[2])
    assert_equal before, Marshal.dump(@account.internal_attributes['toybaco_contract'])
    assert_equal 'preserve', @account.internal_attributes['unrelated']
    assert_equal 'closed', @account.internal_attributes.dig(SERVICE::KEY, 'state')
  end

  def test_no_mutation_before_exact_seven_day_deadline
    deadline = @account.internal_attributes.dig(SERVICE::FAILURE_KEY, 'grace_ends_at')
    assert_equal 'not_due', run_service(now: Time.at(deadline - 1))
    assert_empty @client.calls
    assert_equal 'closed', run_service(now: Time.at(deadline))
  end

  def test_payment_won_race_before_void_preserves_subscription
    @client.void_action = lambda do |client|
      client.invoice['status'] = 'paid'
      client.invoice['amount_paid'] = 19800
      raise Toybaco::Checkout::Error, 'provider rejects already paid invoice'
    end
    assert_equal 'paid', run_service
    assert_equal [:void], @client.calls.map(&:first)
    assert_equal 'past_due', @client.sub['status']
    refute @account.internal_attributes.key?(SERVICE::KEY)
  end

  def test_lost_void_and_cancel_responses_are_read_back
    @client.void_action = lambda do |client|
      client.invoice['status'] = 'void'
      raise Toybaco::Checkout::Error, 'lost void response'
    end
    @client.cancel_action = lambda do |client|
      client.sub['status'] = 'canceled'
      raise Toybaco::Checkout::Error, 'lost cancellation response'
    end
    assert_equal 'closed', run_service
    assert_equal 'closed', run_service
    assert_equal [:void, :cancel], @client.calls.map(&:first)
  end

  def test_failed_void_never_cancels_subscription
    @client.void_action = ->(_) { raise Toybaco::Checkout::Error, 'unavailable' }
    assert_equal 'retry_required', run_service
    assert_equal [:void], @client.calls.map(&:first)
    assert_equal 'past_due', @client.sub['status']
  end

  def test_failed_cancel_keeps_durable_partial_result_for_retry
    @client.cancel_action = ->(_) { raise Toybaco::Checkout::Error, 'unavailable' }
    assert_equal 'retry_required', run_service
    assert_equal 'invoice_voided', @account.internal_attributes.dig(SERVICE::KEY, 'state')
    @client.cancel_action = nil
    assert_equal 'closed', run_service
    assert_equal [:void, :cancel, :cancel], @client.calls.map(&:first)
  end

  %w[processing requires_capture requires_action requires_confirmation succeeded].each do |status|
    define_method("test_#{status}_payment_blocks_void") do
      @client.intents['pi_idle']['status'] = status
      assert_equal 'payment_in_progress', run_service
      assert_empty @client.calls
    end
  end

  def test_paid_or_partially_paid_invoice_never_gets_voided
    @client.invoice['status'] = 'paid'
    assert_equal 'paid', run_service
    @client.invoice['status'] = 'open'
    @client.invoice['amount_paid'] = 100
    assert_equal 'review_required', run_service
    assert_empty @client.calls
  end

  def test_later_payment_page_is_checked_before_void
    payment('pi_later', 'processing')
    first, second = @client.payments
    @client.pages = { nil => { 'data' => [first], 'has_more' => true }, first['id'] => { 'data' => [second], 'has_more' => false } }
    assert_equal 'payment_in_progress', run_service
    assert_empty @client.calls
  end

  def test_duplicate_page_or_missing_pagination_marker_cannot_authorize_cancellation
    first = @client.payments.first
    @client.pages = { nil => { 'data' => [first], 'has_more' => true }, first['id'] => { 'data' => [first], 'has_more' => false } }
    assert_equal 'retry_required', run_service
    @client.pages = { nil => { 'data' => [] } }
    assert_equal 'retry_required', run_service
    assert_empty @client.calls
  end

  def test_other_debts_sibling_contracts_and_shared_customers_are_not_touched
    @client.debts = [@client.invoice.merge('id' => 'in_other')]
    assert_equal 'other_debt', run_service
    @client.debts = []
    @client.siblings = [@client.sub.merge('id' => 'sub_other', 'status' => 'active')]
    assert_equal 'other_debt', run_service
    @client.siblings = []
    Account.ids = [41, 42]
    assert_equal 'other_debt', run_service
    assert_empty @client.calls
  end

  def test_pending_invoice_items_require_review_instead_of_silently_changing_collection
    @client.pending = [{ 'id' => 'ii_other' }]
    assert_equal 'other_debt', run_service
    assert_empty @client.calls
  end

  def test_customer_mode_invoice_and_period_mismatches_fail_closed
    original = Marshal.dump(@client.sub)
    ['customer', 'livemode', 'latest_invoice'].each do |field|
      @client.sub = Marshal.load(original).merge(field => 'mismatch')
      assert_equal 'retry_required', run_service
    end
    @client.sub = Marshal.load(original)
    @client.sub['items']['data'].first['current_period_start'] += 1
    assert_equal 'retry_required', run_service
    assert_empty @client.calls
  end

  def test_replacement_invoice_after_void_prevents_canceling_a_new_period
    @client.void_action = lambda do |client|
      client.invoice['status'] = 'void'
      client.sub['latest_invoice'] = { 'id' => 'in_new' }
    end
    assert_equal 'retry_required', run_service
    assert_equal [:void], @client.calls.map(&:first)
    assert_equal 'invoice_voided', @account.internal_attributes.dig(SERVICE::KEY, 'state')
  end

  def test_old_api_default_intent_is_also_checked
    @client.invoice['payment_intent'] = 'pi_older'
    @client.intents['pi_older'] = @client.intents['pi_idle'].merge('id' => 'pi_older', 'status' => 'processing')
    assert_equal 'payment_in_progress', run_service
    assert_empty @client.calls
  end

  def test_unrelated_payment_never_authorizes_void
    @client.payments.first['invoice'] = 'in_other'
    assert_equal 'retry_required', run_service
    assert_empty @client.calls
  end

  def test_legacy_addons_or_manually_modified_deadlines_are_excluded
    @account.internal_attributes['toybaco_contract']['legacy'] = true
    assert_equal 'not_due', run_service
    @account.internal_attributes['toybaco_contract']['legacy'] = false
    @account.internal_attributes[SERVICE::FAILURE_KEY]['grace_ends_at'] += 1
    assert_equal 'not_due', run_service
    assert_empty @client.calls
  end
  def test_client_uses_delete_without_proration_and_encoded_bounded_list_queries
    captured = []
    response = Net::HTTPOK.new('1.1', '200', 'OK')
    response.define_singleton_method(:body) { '{}' }
    http = Object.new
    http.define_singleton_method(:request) { |request| captured << request; response }
    start = ->(*, **, &block) { block.call(http) }
    client = Toybaco::Checkout::Client.new('sk_test_synthetic')
    Net::HTTP.stub(:start, start) do
      client.cancel_unpaid_subscription('sub_renewal')
      client.void_invoice('in_renewal', idempotency_key: 'fixture-void')
      client.list_invoice_payments('in_renewal', starting_after: 'inpay_second')
      client.list_customer_subscriptions('cus_store')
      client.pending_customer_invoice_items('cus_store')
    end
    assert_equal 'DELETE', captured[0].method
    assert_equal '/v1/subscriptions/sub_renewal', captured[0].path
    assert_equal({ 'invoice_now' => 'false', 'prorate' => 'false' }, URI.decode_www_form(captured[0].body).to_h)
    assert_equal 'POST', captured[1].method
    assert_equal '/v1/invoices/in_renewal/void', captured[1].path
    assert_equal 'fixture-void', captured[1]['Idempotency-Key']
    query = URI.decode_www_form(URI(captured[2].path).query).to_h
    assert_equal({ 'invoice' => 'in_renewal', 'limit' => '100', 'starting_after' => 'inpay_second' }, query)
    assert_equal 'all', URI.decode_www_form(URI(captured[3].path).query).to_h['status']
    assert_equal 'true', URI.decode_www_form(URI(captured[4].path).query).to_h['pending']
  end

  def test_client_rejects_untrusted_path_ids_before_network
    client = Toybaco::Checkout::Client.new('sk_test_synthetic')
    assert_raises(Toybaco::Checkout::Unavailable) { client.retrieve_invoice('in_a/../other') }
    assert_raises(Toybaco::Checkout::Unavailable) { client.cancel_unpaid_subscription('sub_a?expand=secret') }
    assert_raises(Toybaco::Checkout::Unavailable) { client.list_customer_invoices('cus_a/anything') }
  end

end
