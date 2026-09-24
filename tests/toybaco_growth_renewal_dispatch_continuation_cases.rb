# frozen_string_literal: true

module ToybacoGrowthRenewalDispatchContinuationCases
  Growth = Toybaco::Growth
  Dispatch = Growth::RenewalDispatch
  NOW = Time.utc(2026, 9, 24, 8)

  def teardown
    if @dispatch_owner
      Toybaco::GrowthPostingPrincipal.where(account_id: @account.id).delete_all
      Toybaco::GrowthPostingAuthorityCurrent.where(account_id: @account.id).delete_all
      @account.account_users.where(user_id: @dispatch_owner.id).delete_all
      @dispatch_owner.destroy!
    end
    super
  end

  # failure: false leaves only the prior coverage; the sync guard cases accept facts themselves.
  def dispatch_ordinary_fixture(failure: true)
    @dispatch_owner = FactoryBot.create(:user)
    FactoryBot.create(:account_user, account: @account, user: @dispatch_owner, role: 'administrator')
    @dispatch_contract = Toybaco::Entitlements.contract_for(@account)
    starts = NOW.to_i - 3600
    @dispatch_previous_start = starts - 30.days.to_i
    @dispatch_previous = dispatch_subscription(@dispatch_previous_start, starts, 'in_previous', paid: true)
    @subscription = dispatch_subscription(starts, starts + 30.days.to_i, @invoice, paid: false)
    previous = Growth::PaidCoverage.new(@dispatch_previous, @dispatch_contract).verified
    @account.update_columns(internal_attributes: @account.internal_attributes.merge(
      'toybaco_billing_owner_user_id' => @dispatch_owner.id,
      'postiz' => { 'enabled' => true, 'organization_id' => Toybaco::PostizSync.deterministic_organization_id(@account.id) },
      Growth::PurchaseIntent::KEY => { 'state' => 'complete', 'subscription_id' => @sub, 'livemode' => false, 'nonce' => 'a' * 64 },
      Growth::PaidPeriod::KEY => previous))
    test = self
    @client.define_singleton_method(:retrieve_invoice) do |id|
      raise 'Stripe inside Account transaction' if Account.connection.transaction_open?
      [test.instance_variable_get(:@subscription), test.instance_variable_get(:@dispatch_previous)].map { |s| s['latest_invoice'] }
        .find { |i| i['id'] == id }.deep_dup
    end
    @client.define_singleton_method(:list_customer_subscriptions) { |*, **| { 'data' => [test.instance_variable_get(:@subscription).deep_dup], 'has_more' => false } }
    @client.define_singleton_method(:list_customer_invoices) { |*, **| { 'data' => [test.instance_variable_get(:@subscription)['latest_invoice'].deep_dup], 'has_more' => false } }
    @client.define_singleton_method(:pending_customer_invoice_items) { |_| { 'data' => [], 'has_more' => false } }
    @client.define_singleton_method(:list_invoice_payments) { |*, **| { 'data' => [], 'has_more' => false } }
    accept if failure
  end

  def dispatch_subscription(starts, ends, id, paid:)
    amount = 19_800
    line = { 'id' => 'il_fixture', 'type' => 'subscription', 'subscription' => @sub, 'subscription_item' => 'si_renewal',
      'proration' => false, 'price' => { 'id' => 'price_renewal' }, 'quantity' => 1, 'amount' => amount,
      'currency' => 'jpy', 'period' => { 'start' => starts, 'end' => ends }, 'discount_amounts' => [] }
    invoice = { 'id' => id, 'subscription' => @sub, 'customer' => @customer, 'livemode' => false, 'status' => paid ? 'paid' : 'open',
      'billing_reason' => 'subscription_cycle', 'collection_method' => 'charge_automatically', 'currency' => 'jpy',
      'amount_remaining' => paid ? 0 : amount, 'amount_due' => amount, 'amount_paid' => paid ? amount : 0, 'subtotal' => amount,
      'starting_balance' => 0, 'amount_shipping' => 0, 'pre_payment_credit_notes_amount' => 0, 'post_payment_credit_notes_amount' => 0,
      'discounts' => [], 'total_discount_amounts' => [], 'status_transitions' => { 'paid_at' => paid ? starts + 60 : nil },
      'lines' => { 'has_more' => false, 'data' => [line] } }
    { 'id' => @sub, 'customer' => @customer, 'livemode' => false, 'status' => paid ? 'active' : 'past_due',
      'collection_method' => 'charge_automatically', 'pause_collection' => nil, 'pending_update' => nil, 'schedule' => nil,
      'cancel_at_period_end' => false, 'billing_cycle_anchor' => @dispatch_previous_start, 'metadata' => { 'toybaco_purchase_nonce' => 'a' * 64 },
      'items' => { 'has_more' => false, 'data' => [{ 'id' => 'si_renewal', 'quantity' => 1, 'price' => { 'id' => 'price_renewal' },
        'current_period_start' => starts, 'current_period_end' => ends }] }, 'latest_invoice' => invoice }
  end

  def dispatch_real_execute
    Growth::RenewalDispatchExecution.new(dispatch_row, client: @client, environment: ENV, clock: -> { Time.now.utc }).call
  end

  def test_dispatch_real_ordinary_grace_and_paid_preserve_receipts_and_grant_once
    dispatch_ordinary_fixture
    assert_equal 'idle', dispatch_real_execute
    grace = dispatch_row.grace_context.deep_dup
    assert_equal 'grace_ready', dispatch_row.phase
    assert_nil grace.dig('source', 'authority_id')
    period = @subscription['items']['data'][0]
    @subscription = dispatch_subscription(period['current_period_start'], period['current_period_end'], @invoice, paid: true)
    @subscription['latest_invoice']['status_transitions']['paid_at'] = NOW.to_i
    accept(event(type: 'invoice.paid', created: NOW.to_i))
    assert_equal 'idle', dispatch_real_execute
    assert_equal 'paid_ready', dispatch_row.phase
    assert_equal grace, dispatch_row.grace_context
    assert_equal @invoice, @account.reload.internal_attributes.dig(Growth::PaidPeriod::KEY, 'invoice_id')
    count = Toybaco::GrowthAiGrant.where(account_id: @account.id).count
    dispatch_real_execute
    assert_equal count, Toybaco::GrowthAiGrant.where(account_id: @account.id).count
    assert_equal 0, Toybaco::GrowthPostingRenewal.where(account_id: @account.id).count
  end

  def test_dispatch_real_mixed_invoice_never_updates_coverage_or_opens_sync
    dispatch_ordinary_fixture
    old = @account.reload.internal_attributes[Growth::PaidPeriod::KEY]
    @subscription['latest_invoice']['lines']['data'] << @subscription['latest_invoice']['lines']['data'].first.deep_dup
    assert_equal 'pending', dispatch_real_execute
    assert_equal old, @account.reload.internal_attributes[Growth::PaidPeriod::KEY]
    assert Dispatch.blocked?('test', @sub, now: NOW)
    assert_equal 0, Toybaco::GrowthAiGrant.where(account_id: @account.id).count
  end

  def test_dispatch_real_paid_coverage_insert_failure_rolls_back_and_recovers_once
    dispatch_ordinary_fixture
    period = @subscription['items']['data'][0]
    @subscription = dispatch_subscription(period['current_period_start'], period['current_period_end'], @invoice, paid: true)
    @subscription['latest_invoice']['status_transitions']['paid_at'] = NOW.to_i
    old = @account.reload.internal_attributes[Growth::PaidPeriod::KEY]
    original = Growth::PaidPeriod.instance_method(:observe!)
    Growth::PaidPeriod.class_eval do
      define_method(:observe!) do |subscription|
        original.bind_call(self, subscription)
        raise IOError, 'fixture after coverage insert'
      end
    end
    assert_equal 'pending', dispatch_real_execute
    assert_equal old, @account.reload.internal_attributes[Growth::PaidPeriod::KEY]
    assert_equal 0, Toybaco::GrowthAiGrant.where(account_id: @account.id).count
    assert Dispatch.blocked?('test', @sub, now: NOW)
    Growth::PaidPeriod.class_eval { define_method(:observe!, original) }
    travel_to NOW + 31
    assert_equal 'idle', dispatch_real_execute
    assert_equal @invoice, @account.reload.internal_attributes.dig(Growth::PaidPeriod::KEY, 'invoice_id')
    assert_equal 1, Toybaco::GrowthAiGrant.where(account_id: @account.id).count
  ensure
    Growth::PaidPeriod.class_eval { define_method(:observe!, original) } if original
  end

  def test_dispatch_real_owner_epoch_change_cannot_resume_saved_context
    dispatch_ordinary_fixture
    failure = Growth::OrdinaryRenewalEvidence.instance_method(:verify!)
    Growth::OrdinaryRenewalEvidence.class_eval { define_method(:verify!) { |**| raise IOError } }
    assert_equal 'pending', dispatch_real_execute
    context = dispatch_row.grace_context
    refute_nil context
    Growth::OrdinaryRenewalEvidence.class_eval { define_method(:verify!, failure) }
    Account.transaction do
      @account.lock!
      Growth::PostingPrincipal.rotate!(@account.id, user_ids: [@dispatch_owner.id], now: NOW)
    end
    travel_to NOW + 31
    assert_equal 'pending', dispatch_real_execute
    assert_equal context, dispatch_row.grace_context
    assert Dispatch.blocked?('test', @sub, now: Time.now.utc)
  ensure
    Growth::OrdinaryRenewalEvidence.class_eval { define_method(:verify!, failure) } if failure
  end
end
