# frozen_string_literal: true

require Rails.root.join('lib/toybaco/growth/scheduled_downgrade')
require Rails.root.join('lib/toybaco/growth/ai_ledger')
require 'active_support/security_utils'

module ToybacoScheduledDowngradeRuntimeCases
  SD = Toybaco::Growth
  SDRow = Toybaco::GrowthScheduledDowngrade

  def teardown
    if @sd_used
      Toybaco::GrowthScheduledGrantUpgrade.where(account_id: @account.id).delete_all
      SDRow.where(account_id: @account.id).delete_all
      Toybaco::PlanCatalog.define_singleton_method(:default, @sd_catalog_method) if @sd_catalog_method
    end
    super
    Toybaco::SubscriptionSyncRequest.where(id: @sd_sync_requests).delete_all if @sd_sync_requests
  end

  def sd_price(plan)
    terms = Toybaco::PlanCatalog.default.definition(plan, '2026-09-18.1')
    { 'id' => "price_#{plan}#{@sd_cycle}", 'active' => true, 'livemode' => false, 'currency' => 'jpy',
      'unit_amount' => terms.dig('cycles', @sd_cycle, 'amount'), 'billing_scheme' => 'per_unit', 'tax_behavior' => 'exclusive',
      'metadata' => { 'toybaco_plan' => plan, 'toybaco_plan_version' => terms['plan_version'] },
      'recurring' => { 'interval' => @sd_cycle, 'interval_count' => 1, 'usage_type' => 'licensed' },
      'product' => { 'id' => "prod_#{plan}", 'active' => true, 'name' => terms['product_name'], 'description' => terms['description'] } }
  end

  def sd_fixture(cycle: 'month')
    @sd_cycle = cycle
    @sd_used = @renewal_test_used = true
    @n3_old_mode = ENV['TOYBACO_STRIPE_MODE']; ENV['TOYBACO_STRIPE_MODE'] = 'test'
    @sd_catalog_method = Toybaco::PlanCatalog.method(:default)
    data = @sd_catalog_method.call.data.deep_dup
    %w[light standard pro].each do |plan|
      data['current_versions'][plan] = '2026-09-18.1'
      data['plans'][plan]['versions']['2026-09-18.1']['sellable'] = true
      data['plan_changes']['eligible_versions'][plan] = '2026-09-18.1'
    end
    catalog = Toybaco::PlanCatalog.new(data)
    Toybaco::PlanCatalog.define_singleton_method(:default) { catalog }
    n3i_seed_authority
    attrs = @account.reload.internal_attributes
    @n3_subscription_id = attrs['toybaco_subscription_id']; @n3_customer_id = attrs['toybaco_stripe_customer_id']
    @n3_nonce = attrs.dig(SD::PurchaseIntent::KEY, 'nonce')
    source = Toybaco::Entitlements.snapshot_for(catalog.definition('pro', '2026-09-18.1'), cycle: cycle)
                                .merge('stripe_price_id' => "price_pro#{cycle}", 'subscription_item_id' => 'si_fixture')
    @n3_contract = source
    coverage = attrs.fetch(SD::PaidPeriod::KEY).merge(source.slice('plan_id', 'plan_version', 'cycle', 'stripe_price_id'))
                    .merge('normal_limit' => 2000, 'current_base_limit' => 2000)
    if cycle == 'year'
      coverage['term_start'] = (Time.at(coverage['term_end']).utc - 1.year).to_i
      coverage['paid_at'] = coverage['term_start'] + 60
      coverage['anchor'] = coverage['term_start']
    end
    n3_mutate('toybaco_contract' => source, SD::PaidPeriod::KEY => coverage)
    @n3_boundary = coverage['term_end']; @n3_previous_start = coverage['term_start']
    old_sub = n3_subscription(coverage['term_start'], coverage['term_end'], coverage['invoice_id'], paid: true, paid_at: coverage['paid_at'])
    @n3_previous_invoice = old_sub['latest_invoice'].deep_dup
    old_sub['items']['data'][0]['price'] = sd_price('pro')
    @sd_price = sd_price('light')
    service = Toybaco::Checkout::PlanChange.new(account: @account, client: Object.new, catalog: catalog, clock: -> { n3_now })
    selection = { 'plan_id' => 'light', 'plan_version' => '2026-09-18.1', 'cycle' => cycle }
    quote = service.send(:build_quote, old_sub, selection, @owner.id, catalog.definition('light', '2026-09-18.1'), @sd_price)
    first = { 'start_date' => @n3_previous_start, 'end_date' => @n3_boundary, 'items' => [{ 'price' => "price_pro#{cycle}", 'quantity' => 1 }] }
    @sd_schedule = { 'id' => 'sub_sched_fixture', 'subscription' => @n3_subscription_id, 'status' => 'active',
      'metadata' => {}, 'end_behavior' => 'release', 'phases' => [first] }
    receipt = { 'status' => 'reserved', 'quote' => quote, 'schedule_id' => @sd_schedule['id'] }
    receipt['configuration'] = service.send(:schedule_params, @sd_schedule, receipt)
    @sd_schedule.merge!(receipt['configuration'].except('proration_behavior'))
    receipt['schedule_fingerprint'] = service.send(:schedule_fingerprint, @sd_schedule)
    n3_mutate('toybaco_plan_change' => receipt, 'toybaco_subscription_status' => 'past_due')
    @sd_target = Toybaco::Entitlements.snapshot_for(catalog.definition('light', '2026-09-18.1'), cycle: cycle)
                                    .merge('stripe_price_id' => @sd_price['id'], 'subscription_item_id' => 'si_fixture')
    @n3_contract = @sd_target
    n3_time(@n3_boundary + 3600)
    @n3_provider = n3_subscription(@n3_boundary, @sd_schedule['phases'][1]['end_date'], 'in_failed', paid: false)
    @n3_provider['schedule'] = @sd_schedule['id']
    @n3_provider['items']['data'][0]['price'] = @sd_price.deep_dup
    @n3_contract = source
    @sd_event = sd_event
  end

  def sd_event(attempt: 1, created: @n3_boundary, type: 'invoice.payment_failed')
    raw = { 'id' => "evt_sd#{SecureRandom.hex(10)}", 'object' => 'event', 'type' => type, 'livemode' => false, 'created' => created,
      'data' => { 'object' => { 'id' => 'in_failed', 'object' => 'invoice', 'subscription' => @n3_subscription_id,
        'customer' => @n3_customer_id, 'billing_reason' => 'subscription_cycle', 'attempt_count' => attempt } } }
    now = n3_now.to_i; secret = 'whsec_fixture12345678901234567890'; body = JSON.generate(raw)
    sig = "t=#{now},v1=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "#{now}.#{body}")}"
    signed = SD::PaymentSignature.verify!(body, sig, environment: { 'TOYBACO_STRIPE_PACK_WEBHOOK_SECRET' => secret })
    SD::BillingReceipt.accept!(SD::BillingSnapshot.new(signed).read, now: n3_now)
  end

  def sd_client
    test = self
    n3i_client.tap do |client|
      client.define_singleton_method(:retrieve_price) { |_| raise('Stripe in Account transaction') if Account.connection.transaction_open?; test.instance_variable_get(:@sd_price).deep_dup }
      client.define_singleton_method(:retrieve_subscription_schedule) { |_| raise('Stripe in Account transaction') if Account.connection.transaction_open?; test.instance_variable_get(:@sd_schedule).deep_dup }
    end
  end

  def sd_record(event = @sd_event, environment: {}, client: sd_client)
    env = { SD::ScheduledDowngrade::FLAG => 'true', 'TOYBACO_STRIPE_MODE' => 'test' }.merge(environment)
    SD::ScheduledDowngrade.new(event, client: client, now: n3_now, environment: env).record!
  end

  def sd_row = SDRow.find_by!(account_id: @account.id)
  def sd_grant = Toybaco::GrowthAiGrant.find_by!(account_id: @account.id, source_key: "paid:#{@n3_subscription_id}:#{@n3_boundary}:base")

  def sd_paid
    amount = @n3_provider['latest_invoice']['amount_due']
    @n3_provider['status'] = 'active'
    @n3_provider['latest_invoice'].merge!('status' => 'paid', 'amount_remaining' => 0, 'amount_paid' => amount,
                                        'status_transitions' => { 'paid_at' => n3_now.to_i })
    event = sd_event(type: 'invoice.paid', created: n3_now.to_i)
    sd_record(event, environment: { SD::ScheduledDowngrade::FLAG => 'false' })
    assert_equal 'applied', sd_sync

    event
  end

  def sd_sync
    subscription = @n3_provider.deep_dup
    client = Object.new
    client.define_singleton_method(:retrieve_subscription) { |_| subscription.deep_dup }
    Toybaco::SubscriptionSync.new(client: client).call(@account.reload, subscription_id: @n3_subscription_id)
  end

  # The first grace is the source Pro limit (2000) pro rata for 7 days of the
  # failed renewal term, rounded up: 31 days -> 452, 30 days -> 467. The spec
  # fixes the formula, not either number. Derive it from this fixture's term and
  # pin that term (2026-11-02..2026-12-02, 30 days) so the value keeps its meaning.
  def sd_grace_units
    phase = @sd_schedule.fetch('phases').fetch(1)
    term = phase.fetch('end_date') - phase.fetch('start_date')
    assert_equal @n3_boundary, phase.fetch('start_date')
    assert_equal 30.days.to_i, term
    [Rational(2000 * 7.days.to_i, term).ceil, 2000].min
  end

  # Deletes only the Account row for the durable-evidence assertions, then
  # restores the identical row so the shared teardown still takes the real
  # Account#destroy! path (dependents, owner, Current.reset). The destroy guard
  # is unchanged and still rejects a missing Account row.
  def sd_without_account_row
    saved = Account.connection.select_value("SELECT row_to_json(accounts)::text FROM accounts WHERE id = #{Integer(@account.id)}")
    raise 'fixture Account row is missing' unless saved
    raise 'fixture Account row was not deleted' unless Account.where(id: @account.id).delete_all == 1

    yield
  ensure
    if saved && !Account.exists?(@account.id)
      Account.connection.execute("INSERT INTO accounts SELECT * FROM json_populate_record(NULL::accounts, #{Account.connection.quote(saved)}::json)")
    end
  end

  def test_sd_fixed_source_grace_is_signed_durable_and_not_an_ordinary_fact
    sd_fixture
    source = Toybaco::Entitlements.contract_for(@account).deep_dup
    assert SD::ScheduledDowngrade.applicable?(@sd_event)
    assert_equal 'scheduled_downgrade_grace', sd_record
    row = sd_row; old = row.attributes.deep_dup
    assert_equal source, Toybaco::Entitlements.contract_for(@account.reload)
    assert_equal sd_grace_units, sd_grant.units
    assert_equal @n3_boundary + 7.days.to_i, sd_grant.ends_at.to_i
    operation = Toybaco::RenewalOperation.find(row.renewal_operation_id)
    assert_equal 'outside_terms', operation.state
    @account.with_lock { assert_raises(SD::OrdinaryRenewalFact::Invalid) { SD::OrdinaryRenewalFact.read!(operation.id, account: @account, now: n3_now) } }
    n3_time(n3_now.to_i + 3600)
    assert_equal 'scheduled_downgrade_grace', sd_record(sd_event(attempt: 2, created: n3_now.to_i))
    assert_equal old, row.reload.attributes
    assert_equal sd_grace_units, sd_grant.units
  end

  def test_sd_paid_target_below_consumed_and_reserved_keeps_history_and_closes_new_admission
    sd_fixture; sd_record
    grant = sd_grant; grant.update!(used: 120)
    ledger = SD::AiLedger.new(@account, now: n3_now)
    reservation = ledger.reserve(request_key: 'a' * 64, kind: 'post_draft', context_digest: 'b' * 64)
    assert_equal 'reserved', reservation['result']
    operation = Toybaco::GrowthAiOperation.find(reservation['operation_id'])
    old_operation = operation.attributes.deep_dup
    sd_paid
    assert_equal [grant.id, 'included', 121, 120], sd_grant.attributes.values_at('id', 'source', 'units', 'used')
    assert_equal old_operation, operation.reload.attributes
    assert_equal 0, ledger.summary['remaining']
    assert_equal 100, ledger.summary['grants'].first['limit']
    assert_equal 'denied', ledger.reserve(request_key: 'c' * 64, kind: 'post_draft', context_digest: 'd' * 64)['result']
    assert_equal 'consumed', ledger.settle(operation_id: operation.id, token: reservation['token'], outcome: 'consumed') { 'saved-fixture-result' }['result']
    assert_equal 121, sd_grant.used
    assert_equal 0, ledger.summary['remaining']
    SD::PaidPeriod.new(@account, now: n3_now).observe!(@n3_provider)
    assert_equal 121, sd_grant.used
    assert_equal 1, Toybaco::GrowthAiGrant.where(account_id: @account.id, source_key: grant.source_key).count
  end

  def test_sd_paid_below_target_keeps_used_and_subtracts_reservations_once
    sd_fixture; sd_record; sd_grant.update!(used: 20)
    ledger = SD::AiLedger.new(@account, now: n3_now)
    reservation = ledger.reserve(request_key: 'e' * 64, kind: 'post_draft', context_digest: 'f' * 64)
    sd_paid
    assert_equal 79, ledger.summary['remaining']
    ledger.settle(operation_id: reservation['operation_id'], token: reservation['token'], outcome: 'released')
    assert_equal 80, ledger.summary['remaining']
    assert_equal 20, sd_grant.used
  end

  def test_sd_foreign_schedule_target_owner_or_mixed_invoice_cannot_admit
    sd_fixture
    original = @sd_schedule.deep_dup
    @sd_schedule['metadata']['toybaco_operation'] = 'different'
    assert_raises(Toybaco::Checkout::PlanChangeError) { sd_record }
    @sd_schedule = original
    original_invoice = @n3_provider['latest_invoice'].deep_dup
    @n3_provider['latest_invoice']['lines']['data'] << original_invoice['lines']['data'].first.deep_dup
    assert_raises(SD::PostingPreparationRecord::Invalid) { sd_record }
    @n3_provider['latest_invoice'] = original_invoice
    @sd_price['unit_amount'] += 1
    assert_raises(Toybaco::Checkout::Unavailable) { sd_record }
    refute SDRow.where(account_id: @account.id).exists?
    refute Toybaco::GrowthAiGrant.where(account_id: @account.id, source: 'grace').exists?
  end

  def test_sd_flag_outer_transaction_mode_and_first_attempt_fail_closed
    sd_fixture
    assert_raises(SD::PostingPreparationRecord::Invalid) { sd_record(environment: { SD::ScheduledDowngrade::FLAG => 'false' }) }
    assert_raises(SD::PostingPreparationRecord::Invalid) { sd_record(environment: { 'TOYBACO_STRIPE_MODE' => 'live' }) }
    @account.with_lock { assert_raises(SD::PostingPreparationRecord::Invalid) { sd_record } }
    operation = Toybaco::RenewalOperation.find_by!(invoice_id: 'in_failed')
    operation.update!(first_fact_id: nil, first_failed_at: nil, due_at: nil)
    assert_raises(SD::PostingPreparationRecord::Invalid) { sd_record(sd_event(attempt: 2)) }
    refute SDRow.where(account_id: @account.id).exists?
  end

  def test_sd_after_insert_fault_rolls_back_receipt_grant_account_and_permanent_marker
    sd_fixture
    marker = Toybaco::DurableAcceptance::TABLE
    marker_before = Account.connection.select_value("SELECT count(*) FROM #{marker} WHERE capability = 'scheduled-downgrade-grace-v1'")
    before = @account.reload.attributes.deep_dup
    creator = SDRow.method(:create!)
    SDRow.stub(:create!, ->(**attrs) { creator.call(**attrs); raise IOError, 'after insert' }) { assert_raises(IOError) { sd_record } }
    refute SDRow.where(account_id: @account.id).exists?
    assert_equal before, @account.reload.attributes
    assert_equal marker_before, Account.connection.select_value("SELECT count(*) FROM #{marker} WHERE capability = 'scheduled-downgrade-grace-v1'")
    assert_equal 'scheduled_downgrade_grace', sd_record
  end

  def test_sd_source_change_during_stripe_read_cannot_save_a_stale_allowance
    sd_fixture
    client = sd_client; original = client.method(:retrieve_subscription); changed = false
    client.define_singleton_method(:retrieve_subscription) do |id|
      result = original.call(id)
      unless changed
        changed = true
        account = Account.find_by!("internal_attributes ->> 'toybaco_subscription_id' = ?", id)
        account.update!(internal_attributes: account.internal_attributes.merge('toybaco_billing_owner_user_id' => 999_999))
      end
      result
    end
    assert_raises(SD::PostingPreparationRecord::Invalid) { sd_record(client: client) }
    refute SDRow.where(account_id: @account.id).exists?
  end

  def test_sd_due_boundary_never_extends_or_grants_again
    sd_fixture; sd_record
    grant = sd_grant; grant.update!(used: 10)
    n3_time(@n3_boundary + 7.days.to_i)
    refute SD::RenewalGrace.new(@account.reload, now: n3_now).active?
    assert SD::RenewalGrace.new(@account.reload, now: n3_now).expired?
    assert_raises(SD::PostingPreparationRecord::Invalid) { sd_record(sd_event(attempt: 2, created: n3_now.to_i)) }
    assert_equal [sd_grace_units, 10, @n3_boundary + 7.days.to_i], grant.reload.attributes.values_at('units', 'used', 'ends_at').map { |v| v.is_a?(Time) ? v.to_i : v }
  end
  def test_sd_real_signed_billing_execution_routes_the_dedicated_cause
    sd_fixture
    require Rails.root.join('lib/toybaco/growth/billing_execution')
    old = ENV[SD::ScheduledDowngrade::FLAG]
    ENV[SD::ScheduledDowngrade::FLAG] = 'true'
    result = SD::BillingExecution.new(@sd_event, client: sd_client, now: n3_now).send(:verify_renewal!)
    assert_equal 'scheduled_downgrade_grace', result
    assert_equal 1, SDRow.where(account_id: @account.id).count
  ensure
    old.nil? ? ENV.delete(SD::ScheduledDowngrade::FLAG) : ENV[SD::ScheduledDowngrade::FLAG] = old
  end

  def test_sd_paid_event_without_grace_does_not_create_or_block_a_new_allowance
    sd_fixture
    paid = sd_event(type: 'invoice.paid', created: n3_now.to_i)
    refute SD::ScheduledDowngrade.applicable?(paid)
    refute SDRow.where(account_id: @account.id).exists?
    assert_raises(SD::PaymentSignature::Invalid) { SD::RenewalIngressVerification.new(@sd_event, client: sd_client, now: n3_now).record! }
    refute SDRow.where(account_id: @account.id).exists?
  end

  def test_sd_paid_receipt_response_loss_replays_without_changing_original_or_recovery
    sd_fixture; sd_record
    amount = @n3_provider['latest_invoice']['amount_due']
    @n3_provider['status'] = 'active'
    @n3_provider['latest_invoice'].merge!('status' => 'paid', 'amount_remaining' => 0, 'amount_paid' => amount,
                                        'status_transitions' => { 'paid_at' => n3_now.to_i })
    paid = sd_event(type: 'invoice.paid', created: n3_now.to_i)
    assert_equal 'scheduled_downgrade_paid', sd_record(paid)
    before = sd_row.attributes.deep_dup
    n3_time(n3_now.to_i + 60)
    assert_equal 'scheduled_downgrade_paid', sd_record(paid, environment: { SD::ScheduledDowngrade::FLAG => 'false' })
    assert_equal before, sd_row.attributes
    assert_equal 'applied', sd_sync
    assert_equal 'scheduled_downgrade_paid_history', sd_record(paid)
  end

  def test_sd_paid_sync_failure_rolls_back_contract_principal_grant_and_usage
    sd_fixture; sd_record; sd_grant.update!(used: 120)
    amount = @n3_provider['latest_invoice']['amount_due']
    @n3_provider['status'] = 'active'
    @n3_provider['latest_invoice'].merge!('status' => 'paid', 'amount_remaining' => 0, 'amount_paid' => amount,
                                        'status_transitions' => { 'paid_at' => n3_now.to_i })
    paid = sd_event(type: 'invoice.paid', created: n3_now.to_i)
    assert_raises(SD::PostingPreparationRecord::Invalid) { sd_sync }
    sd_record(paid)
    account_before = @account.reload.attributes.deep_dup
    grant_before = sd_grant.attributes.deep_dup
    epochs = Toybaco::GrowthPostingPrincipal.where(account_id: @account.id).order(:id).map(&:attributes)
    SD::TrialLifecycle.stub(:new, ->(*) { raise IOError, 'after grant and contract writes' }) do
      assert_raises(IOError) { sd_sync }
    end
    assert_equal account_before, @account.reload.attributes
    assert_equal grant_before, sd_grant.attributes
    assert_equal epochs, Toybaco::GrowthPostingPrincipal.where(account_id: @account.id).order(:id).map(&:attributes)
    assert sd_row.recovery
    assert_equal 'applied', sd_sync
    assert_equal [120, 120], sd_grant.attributes.values_at('units', 'used')
  end

  def test_sd_yearly_contract_uses_monthly_source_window_and_target_limit
    sd_fixture(cycle: 'year'); sd_record
    value = sd_row.receipt
    window = SD::ScheduledDowngradeRecord.period(value)
    assert_equal @n3_boundary, window['starts_at']
    assert_operator window['ends_at'], :<, value.dig('period', 'term_end')
    expected = SD::Allowance.grace(limit: 2000, period_seconds: window['ends_at'] - window['starts_at'])
    assert_equal expected, sd_grant.units
    sd_grant.update!(used: 120)
    sd_paid
    assert_equal window['ends_at'], sd_grant.ends_at.to_i
    assert_equal 0, SD::AiLedger.new(@account, now: n3_now).summary['remaining']
    assert_equal 120, sd_grant.used
  end

  def test_sd_independent_account_lock_rejects_without_partial_receipt
    sd_fixture
    ready = Queue.new; release = Queue.new
    holder = Thread.new do
      Account.connection_pool.with_connection do
        Account.transaction do
          Account.lock('FOR UPDATE').find(@account.id)
          ready << true; release.pop
        end
      end
    end
    ready.pop
    assert_raises(ActiveRecord::LockWaitTimeout, SD::PostingExecutionContext::Busy) { sd_record }
    refute SDRow.where(account_id: @account.id).exists?
  ensure
    release << true if release
    holder&.join
  end

  def test_sd_deleted_account_keeps_minimal_receipt_and_permanent_capability
    sd_fixture; sd_record
    row = sd_row
    sd_without_account_row do
      # The destroy guard itself still refuses a missing Account row; only the test fixture restores it afterwards.
      assert_raises(Toybaco::Growth::InboxRetention::Invalid) { Account.transaction { Toybaco::Growth::InboxContractBoundary.destroy!(@account) } }
      assert_equal row.receipt_hash, row.reload.receipt_hash
      row.delete
      marker = Account.connection.select_value("SELECT count(*) FROM toybaco_durable_capability_acceptances WHERE capability='scheduled-downgrade-grace-v1'")
      assert_equal 1, marker
    end
  end

  def test_sd_earlier_first_fact_never_keeps_a_later_deadline
    sd_fixture; sd_record
    # A distinct signed first attempt with an earlier timestamp becomes N1's
    # first fact. The immutable old cause is denied, never silently rewritten.
    earlier = sd_event(created: @n3_boundary - 1)
    assert_raises(SD::PostingPreparationRecord::Invalid) { sd_record(earlier) }
    assert_raises(SD::PostingPreparationRecord::Invalid) { SD::RenewalGrace.new(@account.reload, now: n3_now).active? }
    assert_equal @n3_boundary + 7.days.to_i, sd_grant.ends_at.to_i
  end

  def test_sd_hashed_future_cross_operation_and_cross_period_recovery_are_denied
    sd_fixture; sd_record; sd_paid
    row = sd_row
    original = row.attributes.deep_dup
    changes = [
      ->(value) { value['failure']['operation_id'] += 1 },
      ->(value) { value['period']['invoice_id'] = 'in_foreign' },
      ->(value) { value['binding']['contract']['plan_id'] = 'pro' },
      ->(value) { value['coverage']['normal_limit'] += 1 },
      ->(value) { value['verified_at'] = n3_now.to_i + 3600 },
      ->(value) { value['unexpected'] = 'unknown' }
    ]
    changes.each do |change|
      value = original.fetch('recovery').deep_dup; change.call(value)
      row.update!(recovery: value, recovery_hash: SD::PostingPreparationRecord.digest(value))
      assert_raises(SD::PostingPreparationRecord::Invalid) { SD::AiLedger.new(@account, now: n3_now).summary }
      row.update!(recovery: original['recovery'], recovery_hash: original['recovery_hash'])
    end
    row.update!(updated_at: n3_now + 1)
    assert_raises(SD::PostingPreparationRecord::Invalid) { SD::ScheduledDowngradeRecord.validate!(row, now: n3_now) }
    row.update!(updated_at: original['updated_at'])
    assert_equal 100, SD::AiLedger.new(@account, now: n3_now).summary['remaining']
  end

  def test_sd_corrupt_original_shape_with_matching_hash_is_denied
    sd_fixture; sd_record
    row = sd_row
    value = row.receipt.deep_dup.merge('unexpected' => 'unknown')
    Account.connection.exec_update("UPDATE toybaco_growth_scheduled_downgrades SET receipt = #{Account.connection.quote(JSON.generate(value))}::jsonb, " \
                                  "receipt_hash = #{Account.connection.quote(SD::PostingPreparationRecord.digest(value))} WHERE id = #{row.id}")
    assert_raises(SD::PostingPreparationRecord::Invalid) { SD::RenewalGrace.new(@account.reload, now: n3_now).active? }
  end

  def test_sd_worker_failure_after_cause_commit_recovers_one_subscription_revision_with_flag_off
    sd_fixture
    require Rails.root.join('lib/toybaco/growth/billing_execution')
    old = ENV[SD::ScheduledDowngrade::FLAG]; ENV[SD::ScheduledDowngrade::FLAG] = 'true'
    SD::BillingSubscription.stub(:accept!, ->(*) { raise IOError, 'after cause commit before subscription receipt' }) do
      SD::BillingExecution.new(@sd_event, client: sd_client, now: n3_now).call
    end
    assert_equal 'pending', @sd_event.reload.state
    before = sd_row.attributes.deep_dup
    grant = sd_grant.attributes.deep_dup
    ENV[SD::ScheduledDowngrade::FLAG] = 'false'
    n3_time(n3_now.to_i + 31)
    Toybaco::SubscriptionReconciliation::Dispatch.stub(:enqueue, ->(*) { nil }) do
      SD::BillingExecution.new(@sd_event, client: sd_client, now: n3_now).call
    end
    assert_equal ['completed', 'subscription_accepted'], @sd_event.reload.values_at(:state, :result)
    @sd_sync_requests = [@sd_event.subscription_sync_request_id]
    request = Toybaco::SubscriptionSyncRequest.find(@sd_event.subscription_sync_request_id)
    assert_equal [1, 'pending', 0], request.values_at(:requested_revision, :state, :completed_revision)
    assert_equal before, sd_row.attributes
    assert_equal grant, sd_grant.attributes
    SD::BillingExecution.new(@sd_event, client: sd_client, now: n3_now).call
    assert_equal 1, request.reload.requested_revision
  ensure
    old.nil? ? ENV.delete(SD::ScheduledDowngrade::FLAG) : ENV[SD::ScheduledDowngrade::FLAG] = old
  end

  def test_sd_old_terms_keep_the_existing_billing_observation_route
    sd_fixture
    old_terms = Toybaco::PlanCatalog.default.definition('pro', '2026-09-06.1')
    contract = Toybaco::Entitlements.snapshot_for(old_terms, cycle: 'month')
                                   .merge('stripe_price_id' => 'price_old', 'subscription_item_id' => 'si_fixture')
    n3_mutate('toybaco_contract' => contract)
    refute SD::ScheduledDowngrade.applicable?(@sd_event)
    require Rails.root.join('lib/toybaco/growth/billing_execution')
    assert_equal 'outside_growth_terms', SD::BillingExecution.new(@sd_event, client: sd_client, now: n3_now).send(:verify_renewal!)
    refute SDRow.where(account_id: @account.id).exists?
    refute Toybaco::GrowthAiGrant.where(account_id: @account.id, source: 'grace').exists?
  end

end
