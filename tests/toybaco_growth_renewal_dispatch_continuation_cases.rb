# frozen_string_literal: true

module ToybacoGrowthRenewalDispatchContinuationCases
  Growth = Toybaco::Growth
  Dispatch = Growth::RenewalDispatch
  NOW = Time.utc(2026, 9, 24, 8)

  def teardown
    Toybaco::OpeningRequest.where(id: @dispatch_opening_requests).delete_all if @dispatch_opening_requests
    if @dispatch_owner
      Toybaco::GrowthPostingPrincipal.where(account_id: @account.id).delete_all
      Toybaco::GrowthPostingAuthorityCurrent.where(account_id: @account.id).delete_all
      @account.account_users.where(user_id: @dispatch_owner.id).delete_all
      @dispatch_owner.destroy!
    end
    super
  end

  # failure: false leaves only the prior coverage; the sync guard cases accept facts themselves.
  # opening: true is a store opened from the sign-up checkout: no in-app purchase record, a subscription
  # without a purchase nonce, and the immutable opening request that bound this account to it.
  def dispatch_ordinary_fixture(failure: true, opening: false)
    @dispatch_opening = opening
    @dispatch_owner = FactoryBot.create(:user)
    FactoryBot.create(:account_user, account: @account, user: @dispatch_owner, role: 'administrator')
    @dispatch_contract = Toybaco::Entitlements.contract_for(@account)
    starts = NOW.to_i - 3600
    @dispatch_previous_start = starts - 30.days.to_i
    @dispatch_previous = dispatch_subscription(@dispatch_previous_start, starts, 'in_previous', paid: true)
    @subscription = dispatch_subscription(starts, starts + 30.days.to_i, @invoice, paid: false)
    previous = Growth::PaidCoverage.new(@dispatch_previous, @dispatch_contract).verified
    purchase = { Growth::PurchaseIntent::KEY => { 'state' => 'complete', 'subscription_id' => @sub, 'livemode' => false, 'nonce' => 'a' * 48 } }
    @account.update_columns(internal_attributes: @account.internal_attributes.merge(
      'toybaco_billing_owner_user_id' => @dispatch_owner.id,
      'postiz' => { 'enabled' => true, 'organization_id' => Toybaco::PostizSync.deterministic_organization_id(@account.id) },
      Growth::PaidPeriod::KEY => previous).merge(opening ? {} : purchase))
    dispatch_opening_request(subscription_id: @sub) if opening
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

  # The opening request of this account, as OpeningFulfillment commits it with the store.
  def dispatch_opening_request(subscription_id:)
    row = Toybaco::OpeningRequest.create!(mode: 'test', session_id: "cs_test_renewal#{SecureRandom.hex(8)}", state: 'account_ready',
      deadline_at: NOW, subscription_id: subscription_id, account_id: @account.id, owner_id: @dispatch_owner.id,
      contract_digest: Growth::BillingReceipt.snapshot_digest(@dispatch_contract), account_ready_at: NOW - 30.days)
    (@dispatch_opening_requests ||= []) << row.id
    row
  end

  # An opening checkout subscription carries the plan metadata but never a purchase nonce.
  def dispatch_metadata
    return { 'toybaco_purchase_nonce' => 'a' * 48 } unless @dispatch_opening

    { 'toybaco_plan' => 'standard', 'toybaco_plan_version' => '2026-09-25.1', 'toybaco_cycle' => 'month',
      'toybaco_reference_price_id' => 'price_renewal' }
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
      'cancel_at_period_end' => false, 'billing_cycle_anchor' => @dispatch_previous_start, 'metadata' => dispatch_metadata,
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

  # A store opened from the sign-up checkout has no purchase record and its subscription no purchase
  # nonce. Its opening request binds the renewal, and grace and payment continue as for a purchase.
  def test_dispatch_real_opening_store_grace_and_paid_continue_without_purchase_record
    dispatch_ordinary_fixture(opening: true)
    refute @account.reload.internal_attributes.key?(Growth::PurchaseIntent::KEY)
    refute @subscription['metadata'].key?('toybaco_purchase_nonce')
    assert_equal 'idle', dispatch_real_execute
    assert_equal 'grace_ready', dispatch_row.phase
    grace = dispatch_row.grace_context.deep_dup
    assert_equal [@sub, @customer, 'test', nil],
                 grace.dig('source', 'binding').values_at('subscription_id', 'customer_id', 'mode', 'purchase_nonce')
    period = @subscription['items']['data'][0]
    @subscription = dispatch_subscription(period['current_period_start'], period['current_period_end'], @invoice, paid: true)
    @subscription['latest_invoice']['status_transitions']['paid_at'] = NOW.to_i
    accept(event(type: 'invoice.paid', created: NOW.to_i))
    assert_equal 'idle', dispatch_real_execute
    assert_equal 'paid_ready', dispatch_row.phase
    assert_equal grace, dispatch_row.grace_context
    assert_equal @invoice, @account.reload.internal_attributes.dig(Growth::PaidPeriod::KEY, 'invoice_id')
    count = Toybaco::GrowthAiGrant.where(account_id: @account.id).count
    assert_equal 1, count
    dispatch_real_execute
    assert_equal count, Toybaco::GrowthAiGrant.where(account_id: @account.id).count
    refute @account.reload.internal_attributes.key?(Growth::PurchaseIntent::KEY)
    refute Dispatch.blocked?('test', @sub, now: Time.now.utc)
  end

  # Only this account's single opening request of the same subscription and Stripe mode stands in for
  # the purchase record. A present purchase record is never replaced, and nothing is saved on failure.
  def test_dispatch_real_opening_store_without_its_own_opening_request_never_continues
    dispatch_ordinary_fixture(opening: true)
    request = Toybaco::OpeningRequest.where(id: @dispatch_opening_requests).first!
    attrs = @account.reload.internal_attributes.deep_dup
    rebind = ->(values) { Toybaco::OpeningRequest.where(id: request.id).update_all(values) }
    original = request.attributes.slice('subscription_id', 'mode', 'account_id')
    {
      'other subscription' => [-> { rebind.call(subscription_id: "sub_other#{SecureRandom.hex(4)}") }, -> { rebind.call(original) }],
      'other Stripe mode' => [-> { rebind.call(mode: 'live') }, -> { rebind.call(original) }],
      'other account' => [-> { rebind.call(account_id: @account.id + 1_000_000) }, -> { rebind.call(original) }],
      'second opening request' => [-> { @second = dispatch_opening_request(subscription_id: "sub_second#{SecureRandom.hex(4)}") },
                                   -> { Toybaco::OpeningRequest.where(id: @second.id).delete_all }],
      'stale purchase record' => [-> { @account.update_columns(internal_attributes: attrs.merge(Growth::PurchaseIntent::KEY => { 'state' => 'expired' })) },
                                  -> { @account.update_columns(internal_attributes: attrs) }]
    }.each_with_index do |(label, (break_binding, restore)), index|
      travel_to NOW + ((index + 1) * 1.hour)
      break_binding.call
      assert_equal 'pending', dispatch_real_execute, label
      assert_nil dispatch_row.grace_context, label
      assert_equal 'processing_unavailable', dispatch_row.result, label
      restore.call
    end
    travel_to NOW + 6.hours
    assert_equal 'idle', dispatch_real_execute
    assert_equal 'grace_ready', dispatch_row.phase
    assert_nil dispatch_row.grace_context.dig('source', 'binding', 'purchase_nonce')
  end

  # A binding that cannot be derived is never guessed: the row retries without writing the renewal and
  # stops for an operator once its budget ends.
  def test_dispatch_real_opening_store_without_a_binding_needs_attention_and_writes_nothing
    dispatch_ordinary_fixture(opening: true)
    Toybaco::OpeningRequest.where(id: @dispatch_opening_requests).delete_all
    renewal = -> { @account.reload.internal_attributes.except(Growth::RenewalFailureReceipt::KEY) }
    before = renewal.call
    assert_equal 'pending', dispatch_real_execute
    assert_equal 'processing_unavailable', dispatch_row.result
    travel_to dispatch_row.deadline_at + 1
    assert_equal 'attention', dispatch_real_execute
    assert_equal %w[attention retry_limit], dispatch_row.values_at(:state, :result)
    assert_equal [nil, nil], dispatch_row.values_at(:grace_context, :paid_context)
    assert_equal before, renewal.call
    assert_equal 0, Toybaco::GrowthAiGrant.where(account_id: @account.id).count
  end

  def dispatch_n2_source
    Account.transaction do
      account = Growth::PostingPrincipal.locked_account!(@account.id)
      Growth::RenewalCoordinatorContext.capture(account, operation.id, environment: { 'TOYBACO_STRIPE_MODE' => 'test' }, now: Time.now.utc)
    end
  end

  # N2 captures the same binding at the due time: the purchase record's nonce, or no nonce from the
  # opening request of a store opened at sign-up. Anything else stops the admission unchanged.
  { 'purchase_record' => false, 'opening_request' => true }.each do |label, opening|
    define_method("test_dispatch_n2_source_binds_the_#{label}") do
      dispatch_ordinary_fixture(opening: opening)
      # A present purchase record is used as it is, beside an opening request of another subscription.
      dispatch_opening_request(subscription_id: "sub_other#{SecureRandom.hex(4)}") unless opening
      verify(Toybaco::BillingEvent.where(reference_id: @sub).order(:id).first!)
      travel_to operation.due_at + 1
      binding = dispatch_n2_source.fetch('binding')
      assert_equal [@sub, @customer, 'test', opening ? nil : 'a' * 48],
                   binding.values_at('subscription_id', 'customer_id', 'mode', 'purchase_nonce')
      if opening
        Toybaco::OpeningRequest.where(id: @dispatch_opening_requests).update_all(subscription_id: "sub_other#{SecureRandom.hex(4)}")
      else
        attrs = @account.reload.internal_attributes
        @account.update_columns(internal_attributes: attrs.except(Growth::PurchaseIntent::KEY))
      end
      assert_raises(Growth::RenewalCoordinatorRecord::Changed) { dispatch_n2_source }
    end
  end

  # N2 derives through the same function as N3: no opening request of this account, two of them, another
  # subscription or Stripe mode, or a present record that does not match never admit the stop.
  def test_dispatch_n2_source_without_a_derivable_binding_is_not_admitted
    dispatch_ordinary_fixture(opening: true)
    verify(Toybaco::BillingEvent.where(reference_id: @sub).order(:id).first!)
    travel_to operation.due_at + 1
    request = Toybaco::OpeningRequest.where(id: @dispatch_opening_requests).first!
    attrs = @account.reload.internal_attributes.deep_dup
    rebind = ->(values) { Toybaco::OpeningRequest.where(id: request.id).update_all(values) }
    original = request.attributes.slice('subscription_id', 'mode', 'account_id')
    {
      'no opening request of this account' => [-> { rebind.call(account_id: @account.id + 1_000_000) }, -> { rebind.call(original) }],
      'other subscription' => [-> { rebind.call(subscription_id: "sub_other#{SecureRandom.hex(4)}") }, -> { rebind.call(original) }],
      'other Stripe mode' => [-> { rebind.call(mode: 'live') }, -> { rebind.call(original) }],
      'second opening request' => [-> { @second = dispatch_opening_request(subscription_id: "sub_second#{SecureRandom.hex(4)}") },
                                   -> { Toybaco::OpeningRequest.where(id: @second.id).delete_all }],
      'stale purchase record' => [-> { @account.update_columns(internal_attributes: attrs.merge(Growth::PurchaseIntent::KEY => { 'state' => 'expired' })) },
                                  -> { @account.update_columns(internal_attributes: attrs) }]
    }.each do |label, (break_binding, restore)|
      break_binding.call
      assert_raises(Growth::RenewalCoordinatorRecord::Changed, label) { dispatch_n2_source }
      restore.call
    end
    assert_nil dispatch_n2_source.dig('binding', 'purchase_nonce')
  end
end
