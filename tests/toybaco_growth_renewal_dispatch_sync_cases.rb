# frozen_string_literal: true

require 'digest'
require Rails.root.join('lib/toybaco/growth/billing_execution')
require Rails.root.join('lib/toybaco/growth/renewal_dispatch_execution')
require Rails.root.join('lib/toybaco/subscription_reconciliation/execution')

# customer.subscription.updated can arrive before the signed N1 invoice fact. The
# webhook SubscriptionSync must not move a renewal period before its dispatch phase.
# Flag closed without a dispatch row keeps the legacy Sync. Uses the continuation
# fixture (prepended before this module) and the real Sync, dispatch and PaidPeriod.
module ToybacoGrowthRenewalDispatchSyncCases
  Growth = Toybaco::Growth
  Dispatch = Growth::RenewalDispatch
  Reconciliation = Toybaco::SubscriptionReconciliation
  NOW = Time.utc(2026, 9, 24, 8)

  def sync_fixture(paid:)
    dispatch_ordinary_fixture(failure: false)
    @sync_period = @subscription['items']['data'].first.values_at('current_period_start', 'current_period_end')
    @subscription = sync_subscription(paid: paid)
  end

  # Full base price fields let the real SubscriptionSync resolve the saved contract.
  def sync_subscription(paid:, id: @invoice, period: @sync_period, paid_at: NOW.to_i)
    value = dispatch_subscription(*period, id, paid: paid)
    value['items']['data'].first['price'].merge!('currency' => 'jpy', 'unit_amount' => 19_800,
                                                 'recurring' => { 'interval' => 'month', 'interval_count' => 1 })
    value['latest_invoice']['status_transitions']['paid_at'] = paid_at if paid
    value
  end

  def sync_notice_value(created: NOW.to_i - 20)
    { 'id' => "evt_#{SecureRandom.hex(10)}", 'object' => 'event', 'type' => 'customer.subscription.updated', 'livemode' => false,
      'created' => created, 'data' => { 'object' => { 'object' => 'subscription', 'id' => @sub, 'customer' => @customer } } }
  end

  # Signed receipt, then the billing worker records the durable Sync request.
  def sync_notice!(value = sync_notice_value)
    receipt = accept(value)
    Growth::BillingExecution.new(receipt, client: @client, now: Time.now.utc).call
    assert_equal %w[completed subscription_accepted], receipt.reload.values_at(:state, :result)
    Toybaco::SubscriptionSyncRequest.find(receipt.subscription_sync_request_id)
  end

  def sync_fact!(type:, created:)
    receipt = accept(event(type: type, created: created))
    Growth::BillingExecution.new(receipt, client: @client, now: Time.now.utc).call
    assert_equal %w[completed renewal_dispatch_accepted], receipt.reload.values_at(:state, :result)
    receipt
  end

  def sync_execute(sync, client: @client)
    Reconciliation::Execution.new(sync, client: client, now: Time.now.utc).call
  end

  def sync_state
    @account.reload
    [@account.status, @account.internal_attributes, sync_grants]
  end

  # A waiting Sync writes only these status fields. Everything else is contract,
  # coverage, rights or registration and must stay unchanged.
  SYNC_STATUS_FIELDS = %w[toybaco_subscription_status toybaco_cancel_at_period_end].freeze

  def sync_rights
    @account.reload
    [@account.status, @account.internal_attributes.except(*SYNC_STATUS_FIELDS), sync_grants]
  end

  def sync_grants = Toybaco::GrowthAiGrant.where(account_id: @account.id).order(:id).pluck(:source, :source_key, :units, :revoked_at)
  def sync_coverage = @account.reload.internal_attributes[Growth::PaidPeriod::KEY]
  def sync_base_key = "paid:#{@sub}:#{@sync_period.first}:base"
  def sync_base_rows = sync_grants.select { |grant| grant[1] == sync_base_key }
  def sync_rows = Dispatch.model.joins(Growth::RenewalDispatchSyncGuard::JOIN).where('o.subscription_id = ?', @sub)

  def test_dispatch_sync_paid_notice_before_fact_applies_status_only
    sync_fixture(paid: true)
    sync = sync_notice!
    deadline = sync.deadline_at
    before = sync_rights
    refute Dispatch.blocked?('test', @sub, now: NOW)
    assert Dispatch.sync_pending?(@account.reload, @subscription)
    Growth::PaidTransition.stub(:allowed?, ->(*) { raise 'contract application must not run while waiting' }) do
      assert_equal 'renewal_pending', sync_execute(sync)
    end
    assert_equal before, sync_rights
    assert_equal ['active', false], @account.internal_attributes.values_at(*SYNC_STATUS_FIELDS)
    assert_equal ['pending', 'renewal_pending', 0, deadline, NOW + 60, NOW + 60, 0],
                 sync.reload.values_at(:state, :result, :attempts, :deadline_at, :next_attempt_at, :next_enqueue_at, :completed_revision)
    sync.update_columns(attempts: Reconciliation::ATTEMPTS - 1)
    3.times do |index|
      travel_to NOW + (60 * (index + 1))
      assert_equal 'renewal_pending', sync_execute(sync)
    end
    assert_equal ['pending', Reconciliation::ATTEMPTS - 1, deadline], sync.reload.values_at(:state, :attempts, :deadline_at)
    assert_equal before, sync_rights
    refute Toybaco::RenewalOperation.exists?(subscription_id: @sub)
  end

  def test_dispatch_sync_paid_notice_completes_once_after_paid_continuation
    sync_fixture(paid: true)
    sync = sync_notice!
    previous = sync_coverage
    assert_equal 'renewal_pending', sync_execute(sync)
    travel_to NOW + 60
    sync_fact!(type: 'invoice.paid', created: NOW.to_i)
    assert_equal 'renewal_pending', sync_execute(sync)
    assert_equal [0, 'pending', previous], [sync.reload.attempts, sync.state, sync_coverage]
    assert_equal 'idle', dispatch_real_execute
    assert_equal 'paid_ready', dispatch_row.phase
    coverage = sync_coverage
    assert_equal [@invoice, @sync_period.first], coverage.values_at('invoice_id', 'term_start')
    assert_equal 1, sync_base_rows.size
    grants = sync_grants
    travel_to NOW + 120
    assert_equal 'completed', sync_execute(sync)
    assert_equal ['completed', 'applied', sync.requested_revision], sync.reload.values_at(:state, :result, :completed_revision)
    assert_equal [coverage, grants], [sync_coverage, sync_grants]
    assert_equal 'active', @account.internal_attributes['toybaco_subscription_status']
  end

  def test_dispatch_sync_unpaid_notice_waits_until_first_failure_is_grace_ready
    sync_fixture(paid: false)
    sync = sync_notice!
    before = sync_rights
    assert_equal 'renewal_pending', sync_execute(sync)
    assert_equal [before, 'past_due'], [sync_rights, @account.internal_attributes['toybaco_subscription_status']]
    travel_to NOW + 60
    sync_fact!(type: 'invoice.payment_failed', created: NOW.to_i - 30)
    assert_equal 'renewal_pending', sync_execute(sync)
    assert_equal 'idle', dispatch_real_execute
    assert_equal 'grace_ready', dispatch_row.phase
    refute Dispatch.blocked?('test', @sub, now: Time.now.utc)
    refute Dispatch.sync_pending?(@account.reload, @subscription)
    due = dispatch_row.due_at
    assert_nil Dispatch.guard_sync!(@account, @subscription, now: due - 1)
    assert_equal :wait, Dispatch.guard_sync!(@account, @subscription, now: due)
    grants = sync_grants
    travel_to NOW + 120
    assert_equal 'completed', sync_execute(sync)
    assert_equal ['past_due', before[1][Growth::PaidPeriod::KEY]], [@account.reload.internal_attributes['toybaco_subscription_status'], sync_coverage]
    assert_equal grants, sync_grants
    assert_empty(sync_base_rows.select { |grant| grant[0] == 'included' })
  end

  def test_dispatch_sync_paid_after_grace_ready_waits_for_paid_continuation
    sync_fixture(paid: false)
    sync_fact!(type: 'invoice.payment_failed', created: NOW.to_i - 30)
    assert_equal 'idle', dispatch_real_execute
    assert_equal 'grace_ready', dispatch_row.phase
    previous = sync_coverage
    @subscription = sync_subscription(paid: true)
    sync = sync_notice!
    before = sync_rights
    assert_equal 'renewal_pending', sync_execute(sync)
    assert_equal before, sync_rights
    assert_equal [%w[idle grace_ready], previous, 0], [dispatch_row.values_at(:state, :phase), sync_coverage, sync.reload.attempts]
    travel_to NOW + 60
    sync_fact!(type: 'invoice.paid', created: NOW.to_i)
    assert_equal 'pending', dispatch_row.state
    assert_equal 'idle', dispatch_real_execute
    assert_equal 'paid_ready', dispatch_row.phase
    coverage = sync_coverage
    assert_equal @invoice, coverage['invoice_id']
    assert_equal 1, sync_base_rows.size
    grants = sync_grants
    travel_to NOW + 120
    assert_equal 'completed', sync_execute(sync)
    assert_equal [coverage, grants], [sync_coverage, sync_grants]
  end

  def test_dispatch_sync_replayed_old_notice_after_completion_is_noop
    sync_fixture(paid: true)
    value = sync_notice_value
    sync = sync_notice!(value)
    assert_equal 'renewal_pending', sync_execute(sync)
    travel_to NOW + 60
    sync_fact!(type: 'invoice.paid', created: NOW.to_i)
    assert_equal 'idle', dispatch_real_execute
    travel_to NOW + 120
    assert_equal 'completed', sync_execute(sync)
    after = sync_state
    revision = sync.reload.requested_revision
    assert_equal 'completed', sync_execute(sync)
    receipt = accept(value)
    assert_nil Growth::BillingExecution.new(receipt, client: @client, now: Time.now.utc).call
    assert_equal [revision, 'completed'], sync.reload.values_at(:requested_revision, :state)
    travel_to NOW + 180
    replay = sync_notice!(sync_notice_value(created: NOW.to_i - 3600))
    assert_equal [sync.id, revision + 1, 'pending'], replay.values_at(:id, :requested_revision, :state)
    assert_equal 'completed', sync_execute(replay)
    assert_equal after[1][Growth::PaidPeriod::KEY], sync_coverage
    assert_equal after[2], sync_grants
    assert_equal 1, sync_base_rows.size
  end

  def test_dispatch_sync_flag_unset_without_rows_keeps_legacy_sync
    sync_legacy_flow { ENV.delete(Dispatch::FLAG) }
  end

  def test_dispatch_sync_flag_false_without_rows_keeps_legacy_sync
    sync_legacy_flow { ENV[Dispatch::FLAG] = 'false' }
  end

  def sync_legacy_flow
    sync_fixture(paid: true)
    yield
    sync = sync_notice!
    account = @account.reload
    assert Dispatch.sync_pending?(account, @subscription, environment: { Dispatch::FLAG => 'true' })
    refute Dispatch.sync_pending?(account, @subscription, environment: ENV)
    refute sync_rows.exists?
    assert_equal 'completed', sync_execute(sync)
    assert_equal [@invoice, @sync_period.first], sync_coverage.values_at('invoice_id', 'term_start')
    assert_equal 1, sync_base_rows.size
    assert_equal ['completed', 'applied', 1], sync.reload.values_at(:state, :result, :attempts)
    # Coverage of the latest invoice never waits, also after the flag is opened.
    refute Dispatch.sync_pending?(@account.reload, @subscription, environment: { Dispatch::FLAG => 'true' })
  end

  def test_dispatch_sync_same_period_update_invoice_does_not_wait
    sync_fixture(paid: true)
    current = Growth::PaidCoverage.new(@subscription, @dispatch_contract).verified
    @account.update_columns(internal_attributes: @account.reload.internal_attributes.merge(Growth::PaidPeriod::KEY => current))
    @subscription = sync_subscription(paid: true, id: "in_update#{SecureRandom.hex(4)}")
    @subscription['latest_invoice']['billing_reason'] = 'subscription_update'
    cycle = @subscription.deep_dup
    cycle['latest_invoice']['billing_reason'] = 'subscription_cycle'
    assert Dispatch.sync_pending?(@account.reload, cycle)
    refute Dispatch.sync_pending?(@account, @subscription)
    sync = sync_notice!
    assert_equal 'completed', sync_execute(sync)
    assert_equal [@subscription['latest_invoice']['id'], @sync_period.first], sync_coverage.values_at('invoice_id', 'term_start')
    refute sync_rows.exists?
  end

  def test_dispatch_sync_guard_runs_under_the_dispatch_subscription_lock
    sync_fixture(paid: true)
    sync = sync_notice!
    key = Dispatch.lock_key('test', @sub)
    assert_equal Digest::SHA256.digest("toybaco:subscription-reconciliation:test:#{@sub}").unpack1('q>'), key
    conninfo = Account.connection.raw_connection.conninfo_hash.slice(:host, :port, :dbname, :user, :password)
    observed = []
    original = Dispatch.method(:sync_pending?)
    spy = lambda do |*args, **options|
      db = PG.connect(conninfo)
      observed << db.exec("SELECT pg_try_advisory_lock(#{key})").getvalue(0, 0)
      admission = Thread.new do
        Account.connection_pool.with_connection { accept(event(type: 'invoice.paid', created: NOW.to_i)) }
        :accepted
      rescue StandardError => e
        e.class
      end
      observed << admission.value
      original.call(*args, **options)
    ensure
      db&.close
    end
    Dispatch.stub(:sync_pending?, spy) { assert_equal 'renewal_pending', sync_execute(sync) }
    assert_equal ['f', Dispatch::Busy], observed
    refute Toybaco::RenewalOperation.exists?(subscription_id: @sub)

    travel_to NOW + 60
    sync_fact!(type: 'invoice.paid', created: NOW.to_i)
    row_id = dispatch_row.id
    entered = Queue.new
    release = Queue.new
    worker = Thread.new do
      Account.connection_pool.with_connection do
        blocking = lambda do
          entered << true
          release.pop
          'paid_ready'
        end
        Growth::RenewalDispatchExecution.new(Toybaco::GrowthRenewalDispatch.find(row_id), clock: -> { NOW + 60 }, worker: blocking).call
      end
    end
    entered.pop
    unreachable = Object.new
    unreachable.define_singleton_method(:retrieve_subscription) { |_| raise 'provider must not be read while dispatch holds the lock' }
    before = sync.reload.attributes
    assert_equal 'busy', sync_execute(sync, client: unreachable)
    assert_equal before, sync.reload.attributes
    release << true
    assert_equal 'idle', worker.value
  ensure
    release << true if release && worker&.alive?
    worker&.join
  end

  def test_dispatch_sync_decision_table_boundaries
    sync_fixture(paid: true)
    account = @account.reload
    open = sync_subscription(paid: false)
    assert Dispatch.sync_pending?(account, open)
    draft = open.merge('status' => 'active')
    draft['latest_invoice'] = draft['latest_invoice'].merge('status' => 'draft')
    assert Dispatch.sync_pending?(account, draft)
    refute Dispatch.sync_pending?(account, open.merge('status' => 'canceled'))
    refute Dispatch.sync_pending?(account, open.merge('status' => 'incomplete_expired'))
    refute Dispatch.sync_pending?(account, open.merge('latest_invoice' => open['latest_invoice'].merge('status' => 'uncollectible')))
    refute Dispatch.sync_pending?(account, @subscription.merge('latest_invoice' => @invoice))
    refute Dispatch.sync_pending?(account, @subscription.merge('latest_invoice' => nil))
    refute Dispatch.sync_pending?(account, @subscription.merge('id' => "sub_#{SecureRandom.hex(8)}"))
    refute Dispatch.sync_pending?(Account.new(internal_attributes: account.internal_attributes.except(Growth::PaidPeriod::KEY)), @subscription)
  end

  # The Stripe client always expands latest_invoice. An unexpanded renewal cannot
  # establish PaidCoverage, so waiting on it would only risk a permanent wait.
  def test_dispatch_sync_unexpanded_renewal_invoice_never_waits
    sync_fixture(paid: true)
    @subscription = @subscription.merge('latest_invoice' => @invoice)
    previous = sync_coverage
    assert_operator @subscription['items']['data'].first['current_period_start'], :>, previous['term_start']
    refute Dispatch.sync_pending?(@account.reload, @subscription, environment: { Dispatch::FLAG => 'true' })
    sync = sync_notice!
    assert_equal 'completed', sync_execute(sync)
    assert_equal [previous, []], [sync_coverage, sync_grants]
    refute sync_rows.exists?
  end

  def test_dispatch_sync_flag_closed_after_acceptance_still_waits_for_paid_continuation
    sync_fixture(paid: false)
    sync_fact!(type: 'invoice.payment_failed', created: NOW.to_i - 30)
    assert_equal 'idle', dispatch_real_execute
    ENV[Dispatch::FLAG] = 'false'
    previous = sync_coverage
    @subscription = sync_subscription(paid: true)
    sync = sync_notice!
    assert_equal 'renewal_pending', sync_execute(sync)
    assert_equal previous, sync_coverage
    travel_to NOW + 60
    sync_fact!(type: 'invoice.paid', created: NOW.to_i)
    assert_equal 'idle', dispatch_real_execute
    assert_equal 'paid_ready', dispatch_row.phase
    travel_to NOW + 120
    assert_equal 'completed', sync_execute(sync)
    assert_equal @invoice, sync_coverage['invoice_id']
    assert_equal 1, sync_base_rows.size
  end

  # A closed flag creates no row for the next invoice; its Sync returns to the legacy path.
  def test_dispatch_sync_flag_rollback_returns_the_next_invoice_to_legacy_sync
    sync_fixture(paid: true)
    sync = sync_notice!
    assert_equal 'renewal_pending', sync_execute(sync)
    travel_to NOW + 60
    sync_fact!(type: 'invoice.paid', created: NOW.to_i)
    assert_equal 'idle', dispatch_real_execute
    travel_to NOW + 120
    assert_equal 'completed', sync_execute(sync)
    assert_equal %w[idle paid_ready], dispatch_row.values_at(:state, :phase)
    ENV[Dispatch::FLAG] = 'false'
    starts = @sync_period.last
    travel_to Time.at(starts + 3600).utc
    following = "in_next#{SecureRandom.hex(4)}"
    @subscription = sync_subscription(paid: true, id: following, period: [starts, starts + 30.days.to_i], paid_at: starts + 60)
    refute Dispatch.blocked?('test', @sub, now: Time.now.utc)
    refute Dispatch.sync_pending?(@account.reload, @subscription)
    assert Dispatch.sync_pending?(@account, @subscription, environment: { Dispatch::FLAG => 'true' })
    assert_equal 'completed', sync_execute(sync_notice!)
    assert_equal [following, starts], sync_coverage.values_at('invoice_id', 'term_start')
    assert_equal 1, sync_grants.count { |grant| grant[1] == "paid:#{@sub}:#{starts}:base" }
    assert_equal [%w[idle paid_ready]], sync_rows.pluck(:state, :phase)
  end

  # Rows accepted while the flag was open keep their invoice waiting; the sweep still recovers them.
  def test_dispatch_sync_flag_closed_keeps_accepted_invoice_waiting_until_sweep_recovery
    sync_fixture(paid: true)
    sync_fact!(type: 'invoice.paid', created: NOW.to_i - 10)
    ENV[Dispatch::FLAG] = 'false'
    sync = sync_notice!
    before = sync_rights
    assert_equal 'pending', dispatch_row.state
    assert Dispatch.sync_pending?(@account.reload, @subscription)
    assert_equal 'renewal_pending', sync_execute(sync)
    dispatch_row.update_columns(state: 'running', attempts: 1, lease_token: SecureRandom.hex(24), lease_expires_at: NOW + 300)
    travel_to NOW + 60
    assert_equal 'renewal_pending', sync_execute(sync)
    # Pending and ownerless running rows are still 'received': only the status-only Sync runs.
    assert_equal [before, 0, 'active'], [sync_rights, sync.reload.attempts, @account.internal_attributes['toybaco_subscription_status']]
    travel_to NOW + 301
    jobs = ActiveJob::Base.queue_adapter.enqueued_jobs
    jobs.clear
    Growth::RenewalDispatchQueue.sweep(now: Time.now.utc)
    assert(jobs.any? { |job| job[:job] == Toybaco::GrowthRenewalDispatchJob && job[:args] == [dispatch_row.id] })
    assert_equal 'idle', dispatch_real_execute
    assert_equal 'paid_ready', dispatch_row.phase
    assert_equal 'completed', sync_execute(sync)
    assert_equal @invoice, sync_coverage['invoice_id']
    assert_equal 1, sync_base_rows.size
  end

  def test_dispatch_sync_canceled_subscription_with_void_renewal_applies_the_ended_state
    sync_fixture(paid: false)
    assert Dispatch.sync_pending?(@account.reload, @subscription)
    @subscription['status'] = 'canceled'
    @subscription['latest_invoice']['status'] = 'void'
    before = @account.internal_attributes
    refute Dispatch.sync_pending?(@account, @subscription)
    sync = sync_notice!
    assert_equal 'completed', sync_execute(sync)
    attrs = @account.reload.internal_attributes
    assert_equal before.values_at('toybaco_contract', Growth::PaidPeriod::KEY), attrs.values_at('toybaco_contract', Growth::PaidPeriod::KEY)
    assert_equal ['suspended', 'canceled', true, false],
                 [@account.status, attrs['toybaco_subscription_status'], attrs['toybaco_billing_suspended'], attrs.dig('postiz', 'enabled')]
    assert_empty sync_grants
    refute sync_rows.exists?
    refute Toybaco::RenewalOperation.exists?(subscription_id: @sub)
    # The exempt ended state takes the full Sync also behind an accepted 'received' row.
    sync_fact!(type: 'invoice.payment_failed', created: NOW.to_i - 30)
    refute Dispatch.sync_pending?(@account.reload, @subscription)
    assert Dispatch.blocked?('test', @sub, now: Time.now.utc)
    assert_nil Dispatch.guard_sync!(@account, @subscription, now: Time.now.utc)
  end

  def test_dispatch_sync_void_renewal_on_active_subscription_does_not_wait
    sync_fixture(paid: false)
    @subscription['status'] = 'active'
    @subscription['latest_invoice']['status'] = 'void'
    previous = sync_coverage
    refute Dispatch.sync_pending?(@account, @subscription)
    sync = sync_notice!
    assert_equal 'completed', sync_execute(sync)
    assert_equal [previous, 'active', 'active'], [sync_coverage, @account.status, @account.internal_attributes['toybaco_subscription_status']]
    assert_empty sync_grants
    refute sync_rows.exists?
  end

  # Regression for the mutual wait: a stale cancel flag would make N3 reject billing_idle?.
  def test_dispatch_sync_status_only_repairs_stale_cancel_flag_before_paid_continuation
    sync_fixture(paid: true)
    @account.update_columns(internal_attributes: @account.reload.internal_attributes.merge('toybaco_cancel_at_period_end' => true))
    sync = sync_notice!
    before = sync_rights
    assert_equal 'renewal_pending', sync_execute(sync)
    assert_equal [before, false, 0], [sync_rights, @account.internal_attributes['toybaco_cancel_at_period_end'], sync.reload.attempts]
    refute sync_rows.exists?
    travel_to NOW + 60
    sync_fact!(type: 'invoice.paid', created: NOW.to_i)
    assert_equal 'idle', dispatch_real_execute
    assert_equal 'paid_ready', dispatch_row.phase
    travel_to NOW + 120
    assert_equal 'completed', sync_execute(sync)
    assert_equal @invoice, sync_coverage['invoice_id']
    assert_equal 1, sync_base_rows.size
  end

  # Grok [high]: status-only only repairs and never writes a new cancel reservation. The
  # existing N3 evidence refuses a fresh cancel_at_period_end=true by itself, whatever the
  # saved flag; once the reservation is cleared the renewal completes, and a later
  # reservation is reflected by the full Sync.
  def test_dispatch_sync_status_only_never_writes_a_new_cancel_reservation
    sync_fixture(paid: true)
    @account.update_columns(internal_attributes: @account.reload.internal_attributes.merge('toybaco_cancel_at_period_end' => false))
    @subscription['cancel_at_period_end'] = true
    sync_fact!(type: 'invoice.paid', created: NOW.to_i - 10)
    sync = sync_notice!
    before = sync_rights
    assert_equal 'renewal_pending', sync_execute(sync)
    assert_equal [before, false, 'active'], [sync_rights, @account.internal_attributes['toybaco_cancel_at_period_end'],
                                             @account.internal_attributes['toybaco_subscription_status']]
    assert_equal 'pending', dispatch_real_execute
    assert_equal %w[pending received processing_unavailable], dispatch_row.values_at(:state, :phase, :result)
    @subscription['cancel_at_period_end'] = false
    travel_to NOW + 31
    assert_equal 'idle', dispatch_real_execute
    assert_equal 'paid_ready', dispatch_row.phase
    travel_to NOW + 61
    assert_equal 'completed', sync_execute(sync)
    assert_equal [@invoice, false], [sync_coverage['invoice_id'], @account.internal_attributes['toybaco_cancel_at_period_end']]
    assert_equal 1, sync_base_rows.size
    @subscription['cancel_at_period_end'] = true
    travel_to NOW + 121
    assert_equal 'completed', sync_execute(sync_notice!)
    assert_equal [true, @invoice], [@account.reload.internal_attributes['toybaco_cancel_at_period_end'], sync_coverage['invoice_id']]
  end

  # status-only writes two status fields: saved billing flags and access stay as they are.
  def test_dispatch_sync_status_only_keeps_saved_billing_flags_and_access
    sync_fixture(paid: true)
    flags = { 'toybaco_billing_review' => true, 'toybaco_billing_payment_pending' => true }
    @account.update_columns(internal_attributes: @account.reload.internal_attributes.merge(flags))
    sync = sync_notice!
    before = sync_rights
    assert_equal 'renewal_pending', sync_execute(sync)
    assert_equal [before, flags], [sync_rights, @account.internal_attributes.slice(*flags.keys)]
    cleared = @account.internal_attributes.merge(flags.transform_values { false }).merge('toybaco_billing_suspended' => true)
    @account.update_columns(status: 'suspended', internal_attributes: cleared)
    suspended = sync_rights
    travel_to NOW + 60
    assert_equal 'renewal_pending', sync_execute(sync)
    assert_equal suspended, sync_rights
    assert_equal ['suspended', true], [@account.status, @account.internal_attributes['toybaco_billing_suspended']]
  end

  # status-only never suspends; the access policy waits for the full Sync after the dispatch phase.
  def test_dispatch_sync_status_only_never_suspends_and_the_full_sync_applies_policy_after_grace
    sync_fixture(paid: false)
    @subscription['status'] = 'unpaid'
    sync = sync_notice!
    before = sync_rights
    assert_equal 'renewal_pending', sync_execute(sync)
    assert_equal [before, 'unpaid', true], [sync_rights, @account.internal_attributes['toybaco_subscription_status'],
                                            @account.internal_attributes.dig('postiz', 'enabled')]
    refute @account.internal_attributes.key?('toybaco_billing_suspended')
    # The dispatch evidence needs the dunning status of the first failure.
    @subscription['status'] = 'past_due'
    travel_to NOW + 60
    sync_fact!(type: 'invoice.payment_failed', created: NOW.to_i - 30)
    assert_equal 'idle', dispatch_real_execute
    assert_equal 'grace_ready', dispatch_row.phase
    @subscription['status'] = 'unpaid'
    travel_to NOW + 120
    assert_equal 'completed', sync_execute(sync)
    attrs = @account.reload.internal_attributes
    assert_equal ['suspended', 'unpaid', true, false],
                 [@account.status, attrs['toybaco_subscription_status'], attrs['toybaco_billing_suspended'], attrs.dig('postiz', 'enabled')]
    assert_equal [before[1][Growth::PaidPeriod::KEY], before[2]], [attrs[Growth::PaidPeriod::KEY], sync_grants]
  end

  def test_dispatch_sync_status_only_leaves_child_stores_untouched
    sync_fixture(paid: true)
    contract = Toybaco::Entitlements.contract_for(@account.reload)
    child = Account.create!(name: 'Store child', locale: 'ja')
    store = { 'parent_account_id' => @account.id, 'subscription_id' => @sub, 'subscription_item_id' => 'si_store', 'slot' => 1,
              'child_account_id' => child.id, 'administrator_id' => @dispatch_owner.id, 'addon_id' => 'opt-store',
              'addon_version' => '2026-09-06.1', 'stripe_price_id' => 'price_store', 'cycle' => 'month', 'unit_amount' => 5_500,
              'contract' => contract }
    child.update_columns(internal_attributes: { 'toybaco_contract' => contract, Toybaco::StoreFulfillment::PURCHASE => store,
                                                'toybaco_store_state' => 'active' })
    @account.update_columns(internal_attributes: @account.internal_attributes.merge(Toybaco::StoreFulfillment::REGISTRY => { 'si_store:1' => store }))
    before = [child.reload.status, child.internal_attributes]
    sync = sync_notice!
    assert_equal 'renewal_pending', sync_execute(sync)
    assert_equal before, [child.reload.status, child.internal_attributes]
    refute @account.reload.internal_attributes.key?('toybaco_store_review')
  ensure
    child&.destroy!
  end

  def sync_unreachable
    client = Object.new
    client.define_singleton_method(:retrieve_subscription) { |_| raise 'provider must not be read behind the barrier' }
    client
  end

  # N1 first: the dispatch rejects the stale cancel flag and retries; the blocked Sync
  # still takes the status-only step because the row is only 'received' and N2 has not started.
  def test_dispatch_sync_n1_first_stale_flag_is_repaired_by_status_only_sync
    sync_fixture(paid: true)
    @account.update_columns(internal_attributes: @account.reload.internal_attributes.merge('toybaco_cancel_at_period_end' => true))
    sync_fact!(type: 'invoice.paid', created: NOW.to_i - 10)
    assert_equal 'pending', dispatch_real_execute
    assert_equal %w[pending received processing_unavailable], dispatch_row.values_at(:state, :phase, :result)
    sync = sync_notice!
    before = sync_rights
    assert Dispatch.repair_admissible?('test', @sub, now: NOW)
    assert_equal 'renewal_pending', sync_execute(sync)
    assert_equal [before, false, 0], [sync_rights, @account.internal_attributes['toybaco_cancel_at_period_end'], sync.reload.attempts]
    assert_equal %w[pending received], dispatch_row.values_at(:state, :phase)
    travel_to NOW + 31
    assert_equal 'idle', dispatch_real_execute
    assert_equal 'paid_ready', dispatch_row.phase
    travel_to NOW + 61
    assert_equal 'completed', sync_execute(sync)
    assert_equal @invoice, sync_coverage['invoice_id']
    assert_equal 1, sync_base_rows.size
  end

  def test_dispatch_sync_pre_claim_barrier_keeps_a_rearmed_grace_row_out
    sync_fixture(paid: false)
    sync_fact!(type: 'invoice.payment_failed', created: NOW.to_i - 30)
    assert_equal 'idle', dispatch_real_execute
    @subscription = sync_subscription(paid: true)
    travel_to NOW + 60
    sync_fact!(type: 'invoice.paid', created: NOW.to_i)
    assert_equal %w[pending grace_ready], dispatch_row.values_at(:state, :phase)
    sync = sync_notice!
    before = sync_state
    refute Dispatch.repair_admissible?('test', @sub, now: Time.now.utc)
    assert_equal 'renewal_pending', sync_execute(sync, client: sync_unreachable)
    assert_equal before, sync_state
    sync_assert_deferred(sync, at: Time.now.utc)
  end

  # The pre-claim barrier only moves the retry slot; attempts, deadline and state stay.
  def sync_assert_deferred(sync, at:)
    deadline = sync.deadline_at
    assert_equal [at + 60, at + 60, 0, 'pending', deadline],
                 sync.reload.values_at(:next_attempt_at, :next_enqueue_at, :attempts, :state, :deadline_at)
  end

  def test_dispatch_sync_pre_claim_barrier_keeps_a_due_grace_row_out
    sync_fixture(paid: false)
    sync_fact!(type: 'invoice.payment_failed', created: NOW.to_i - 30)
    assert_equal 'idle', dispatch_real_execute
    due = dispatch_row.due_at
    sync = sync_notice!
    sync.update_columns(deadline_at: due + Dispatch::DEADLINE)
    travel_to due
    before = sync_state
    refute Dispatch.repair_admissible?('test', @sub, now: due)
    assert_equal 'renewal_pending', sync_execute(sync, client: sync_unreachable)
    assert_equal before, sync_state
    sync_assert_deferred(sync, at: due)
  end

  def test_dispatch_sync_pre_claim_barrier_keeps_a_started_n2_out
    sync_fixture(paid: true)
    sync_fact!(type: 'invoice.paid', created: NOW.to_i - 10)
    assert Dispatch.repair_admissible?('test', @sub, now: NOW)
    coordinator = Toybaco::GrowthRenewalCoordinator.create!(account_id: @account.id, renewal_operation_id: operation.id,
                                                            operation_id: SecureRandom.hex(32), receipt_hash: SecureRandom.hex(32),
                                                            receipt: { 'fixture' => true }, due_at: NOW - 60)
    assert_equal %w[pending received], dispatch_row.values_at(:state, :phase)
    sync = sync_notice!
    before = sync_state
    refute Dispatch.repair_admissible?('test', @sub, now: NOW)
    assert_equal 'renewal_pending', sync_execute(sync, client: sync_unreachable)
    assert_equal before, sync_state
    sync_assert_deferred(sync, at: NOW)
    # After N2 has started, even an exempt ended state waits until N2 closes the row.
    @subscription['status'] = 'canceled'
    @subscription['latest_invoice']['status'] = 'void'
    travel_to NOW + 60
    assert_equal 'renewal_pending', sync_execute(sync, client: sync_unreachable)
    assert_equal before, sync_state
    sync_assert_deferred(sync, at: NOW + 60)
  ensure
    coordinator&.delete
  end

  # An exempt ended state cannot establish PaidCoverage. Behind a 'received' row the full
  # Sync applies the ended state instead of hiding it behind the status-only Sync.
  def test_dispatch_sync_exemption_takes_priority_over_a_received_row
    sync_fixture(paid: false)
    sync_fact!(type: 'invoice.payment_failed', created: NOW.to_i - 30)
    @subscription['status'] = 'canceled'
    @subscription['latest_invoice']['status'] = 'void'
    assert Dispatch.blocked?('test', @sub, now: NOW)
    assert Dispatch.repair_admissible?('test', @sub, now: NOW)
    before = @account.reload.internal_attributes
    sync = sync_notice!
    assert_equal 'completed', sync_execute(sync)
    attrs = @account.reload.internal_attributes
    assert_equal ['suspended', 'canceled', true, false],
                 [@account.status, attrs['toybaco_subscription_status'], attrs['toybaco_billing_suspended'], attrs.dig('postiz', 'enabled')]
    assert_equal before.values_at('toybaco_contract', Growth::PaidPeriod::KEY), attrs.values_at('toybaco_contract', Growth::PaidPeriod::KEY)
    assert_empty sync_grants
    assert_equal %w[pending received], dispatch_row.values_at(:state, :phase)
  end

  # status-only lifts no fence: the repaired flag helps the operator, the row stays in attention.
  def test_dispatch_sync_attention_row_at_received_gets_status_only_repair
    sync_fixture(paid: true)
    @account.update_columns(internal_attributes: @account.reload.internal_attributes.merge('toybaco_cancel_at_period_end' => true))
    sync_fact!(type: 'invoice.paid', created: NOW.to_i - 10)
    dispatch_row.update_columns(state: 'attention', result: 'retry_limit')
    sync = sync_notice!
    before = sync_rights
    assert_equal 'renewal_pending', sync_execute(sync)
    assert_equal [before, false], [sync_rights, @account.internal_attributes['toybaco_cancel_at_period_end']]
    assert_equal %w[attention received retry_limit], dispatch_row.values_at(:state, :phase, :result)
    jobs = ActiveJob::Base.queue_adapter.enqueued_jobs
    jobs.clear
    travel_to NOW + 3600
    Growth::RenewalDispatchQueue.sweep(now: Time.now.utc)
    refute(jobs.any? { |job| job[:job] == Toybaco::GrowthRenewalDispatchJob })
    assert Dispatch.blocked?('test', @sub, now: Time.now.utc)
  end

  # Astra [high]: a status-only suspend and resume would leave posting disabled, and N3
  # requires it enabled. status-only keeps access untouched until the full Sync.
  def test_dispatch_sync_status_only_keeps_posting_enabled_for_the_paid_continuation
    sync_fixture(paid: false)
    @subscription['status'] = 'unpaid'
    sync = sync_notice!
    assert_equal 'renewal_pending', sync_execute(sync)
    assert_equal ['active', true], [@account.reload.status, @account.internal_attributes.dig('postiz', 'enabled')]
    @subscription = sync_subscription(paid: true)
    travel_to NOW + 60
    assert_equal 'renewal_pending', sync_execute(sync_notice!)
    assert_equal ['active', true, 'active'], [@account.reload.status, @account.internal_attributes.dig('postiz', 'enabled'),
                                              @account.internal_attributes['toybaco_subscription_status']]
    sync_fact!(type: 'invoice.paid', created: NOW.to_i)
    assert_equal 'idle', dispatch_real_execute
    assert_equal 'paid_ready', dispatch_row.phase
    travel_to NOW + 120
    assert_equal 'completed', sync_execute(sync)
    assert_equal @invoice, sync_coverage['invoice_id']
    assert_equal 1, sync_base_rows.size
  end

  # Astra [medium]: the pre-claim check ran before the grace due, the provider read crossed
  # it. The in-lock decision is taken again with one `now` and writes nothing.
  def test_dispatch_sync_due_crossed_during_the_provider_read_waits_without_writes
    sync_due_crossing_waits
  end

  # A due crossed during the read also keeps an exempt ended state waiting for N2 to
  # close its row, exactly like the pre-claim barrier.
  def test_dispatch_sync_exempt_state_crossing_the_due_waits_for_n2
    sync_due_crossing_waits do |subscription|
      subscription['status'] = 'canceled'
      subscription['latest_invoice']['status'] = 'void'
    end
  end

  def sync_due_crossing_waits
    sync_fixture(paid: false)
    sync_fact!(type: 'invoice.payment_failed', created: NOW.to_i - 30)
    assert_equal 'idle', dispatch_real_execute
    due = dispatch_row.due_at
    sync = sync_notice!
    sync.update_columns(deadline_at: due + Dispatch::DEADLINE)
    travel_to due - 5
    refute Dispatch.blocked?('test', @sub, now: Time.now.utc)
    yield @subscription if block_given?
    assert_equal :wait, Dispatch.guard_sync!(@account.reload, @subscription, now: due + 1)
    test = self
    crossing = Object.new
    crossing.define_singleton_method(:retrieve_subscription) do |_|
      test.travel_to(due + 1)
      test.instance_variable_get(:@subscription).deep_dup
    end
    before = sync_state
    assert_equal 'renewal_pending', Reconciliation::Execution.new(sync, client: crossing).call
    assert_equal [before, 0, 'pending'], [sync_state, sync.reload.attempts, sync.state]
    assert_equal %w[idle grace_ready], dispatch_row.values_at(:state, :phase)
  end

  # Waiting does not extend the deadline. claim! ends an in-lock wait in a renewal_pending
  # attention, and the dispatch completion (enqueue_sync!) re-arms and enqueues it.
  def test_dispatch_sync_in_lock_wait_attention_is_rearmed_by_the_dispatch_completion
    sync_fixture(paid: true)
    sync = sync_notice!
    assert_equal 'renewal_pending', sync_execute(sync)
    travel_to NOW + 600
    sync_fact!(type: 'invoice.paid', created: NOW.to_i + 600)
    travel_to sync.reload.deadline_at + 60
    assert_equal 'attention', sync_execute(sync)
    assert_equal ['attention', 'renewal_pending', 0], sync.reload.values_at(:state, :result, :attempts)
    revision = sync.requested_revision
    jobs = ActiveJob::Base.queue_adapter.enqueued_jobs
    jobs.clear
    assert_equal 'idle', dispatch_real_execute
    assert_equal 'paid_ready', dispatch_row.phase
    assert_equal ['pending', 0, nil, revision + 1, Time.now.utc + Reconciliation::DEADLINE],
                 sync.reload.values_at(:state, :attempts, :result, :requested_revision, :deadline_at)
    sync_assert_enqueued_once(jobs, sync)
    assert_equal 'completed', sync_execute(sync)
    assert_equal @invoice, sync_coverage['invoice_id']
    assert_equal 1, sync_base_rows.size
  end

  # enqueue_sync! re-arms before BillingSubscription.accept!, whose enqueue then queues the
  # re-armed request exactly once.
  def sync_assert_enqueued_once(jobs, sync)
    assert_equal 1, jobs.count { |job| job[:job] == Toybaco::SubscriptionReconciliationJob && job[:args] == [sync.id] }
  end

  # A grace row re-armed by invoice.paid keeps the pre-claim barrier closed.
  def sync_rearmed_grace_barrier
    sync_fixture(paid: false)
    sync_fact!(type: 'invoice.payment_failed', created: NOW.to_i - 30)
    assert_equal 'idle', dispatch_real_execute
    @subscription = sync_subscription(paid: true)
    travel_to NOW + 60
    sync_fact!(type: 'invoice.paid', created: NOW.to_i)
    assert_equal %w[pending grace_ready], dispatch_row.values_at(:state, :phase)
    sync_notice!
  end

  # The pre-claim barrier also ends at the deadline with the claim! expiry rule: an empty
  # or renewal_pending last result is a waiting cause, attempts unchanged, re-armed by the
  # next notice.
  def test_dispatch_sync_pre_claim_wait_reaching_the_deadline_is_rearmed_by_the_next_notice
    sync = sync_rearmed_grace_barrier
    assert_nil sync.result
    travel_to sync.deadline_at + 1
    assert_equal 'attention', sync_execute(sync, client: sync_unreachable)
    assert_equal ['attention', 'renewal_pending', 0], sync.reload.values_at(:state, :result, :attempts)
    rearmed = sync_notice!
    assert_equal [sync.id, 'pending', 0, nil, Time.now.utc + Reconciliation::DEADLINE],
                 rearmed.values_at(:id, :state, :attempts, :result, :deadline_at)
    rearmed.update_columns(result: 'renewal_pending')
    travel_to rearmed.deadline_at + 1
    assert_equal 'attention', sync_execute(rearmed, client: sync_unreachable)
    assert_equal %w[attention renewal_pending], rearmed.reload.values_at(:state, :result)
    assert_equal ['pending', 0], sync_notice!.values_at(:state, :attempts)
  end

  # Astra [medium]: after a real failure the pre-claim expiry is retry_limit, which neither
  # a new notice nor the dispatch completion re-arms.
  def test_dispatch_sync_pre_claim_expiry_after_a_real_failure_is_never_rearmed
    sync = sync_rearmed_grace_barrier
    sync.update_columns(result: 'processing_unavailable')
    travel_to sync.deadline_at + 1
    assert_equal 'attention', sync_execute(sync, client: sync_unreachable)
    assert_equal ['attention', 'retry_limit', 0], sync.reload.values_at(:state, :result, :attempts)
    revision = sync.requested_revision
    assert_equal ['attention', 'retry_limit', revision], sync_notice!.values_at(:state, :result, :requested_revision)
    assert_equal 'idle', dispatch_real_execute
    assert_equal 'paid_ready', dispatch_row.phase
    assert_equal ['attention', 'retry_limit', revision], sync.reload.values_at(:state, :result, :requested_revision)
  end

  # A running request (a crash inside its last claim) keeps its state behind the barrier;
  # claim! applies the expiry rule once the barrier lifts, here retry_limit at the limit.
  def test_dispatch_sync_pre_claim_barrier_leaves_a_crashed_running_request_to_claim
    sync = sync_rearmed_grace_barrier
    sync.update_columns(state: 'running', attempts: Reconciliation::ATTEMPTS, result: nil)
    travel_to sync.deadline_at + 1
    assert_equal 'renewal_pending', sync_execute(sync, client: sync_unreachable)
    assert_equal ['running', Reconciliation::ATTEMPTS, Time.now.utc + 60], sync.reload.values_at(:state, :attempts, :next_attempt_at)
    assert_equal 'idle', dispatch_real_execute
    assert_equal ['paid_ready', 'running'], [dispatch_row.phase, sync.reload.state]
    travel_to Time.now.utc + 61
    assert_equal 'attention', sync_execute(sync)
    assert_equal %w[attention retry_limit], sync.reload.values_at(:state, :result)
    revision = sync.requested_revision
    assert_equal ['attention', 'retry_limit', revision], sync_notice!.values_at(:state, :result, :requested_revision)
  end

  # Attention from a real failure keeps the existing rule: neither the dispatch completion
  # nor a new notice re-arms it.
  def test_dispatch_sync_real_failure_attention_is_not_rearmed_by_the_dispatch_or_a_notice
    sync_fixture(paid: true)
    sync_fact!(type: 'invoice.paid', created: NOW.to_i - 10)
    sync = sync_notice!
    sync.update_columns(result: 'processing_unavailable', deadline_at: NOW - 1)
    assert_equal 'attention', sync_execute(sync)
    assert_equal %w[attention retry_limit], sync.reload.values_at(:state, :result)
    revision = sync.requested_revision
    assert_equal 'idle', dispatch_real_execute
    assert_equal 'paid_ready', dispatch_row.phase
    assert_equal ['attention', 'retry_limit', revision], sync.reload.values_at(:state, :result, :requested_revision)
    %w[retry_limit binding_unresolved].each do |result|
      sync.update_columns(state: 'attention', result: result)
      revision = sync.reload.requested_revision
      travel_to Time.now.utc + 60
      assert_equal [sync.id, 'attention', result, revision], sync_notice!.values_at(:id, :state, :result, :requested_revision)
    end
  end

  # Astra [medium]: the dispatch completion can overtake a waiting request that passed its
  # deadline before any claim! ran. enqueue_sync! re-arms it instead of leaving it to a
  # later claim! attention that nothing would resume.
  def test_dispatch_sync_dispatch_completion_rearms_an_expired_waiting_request
    sync_expired_pending_rearm(claimed_once: true)
  end

  # The same with result nil: a queue outage kept the request from ever being claimed.
  def test_dispatch_sync_dispatch_completion_rearms_an_expired_unclaimed_request
    sync_expired_pending_rearm(claimed_once: false)
  end

  def sync_expired_pending_rearm(claimed_once:)
    sync_fixture(paid: true)
    sync = sync_notice!
    if claimed_once
      assert_equal 'renewal_pending', sync_execute(sync)
      assert_equal 'renewal_pending', sync.reload.result
    else
      assert_nil sync.result
    end
    travel_to NOW + 600
    sync_fact!(type: 'invoice.paid', created: NOW.to_i + 600)
    travel_to sync.reload.deadline_at + 60
    assert_equal 'pending', sync.state
    revision = sync.requested_revision
    jobs = ActiveJob::Base.queue_adapter.enqueued_jobs
    jobs.clear
    assert_equal 'idle', dispatch_real_execute
    assert_equal 'paid_ready', dispatch_row.phase
    assert_equal ['pending', 0, nil, revision + 1, Time.now.utc + Reconciliation::DEADLINE],
                 sync.reload.values_at(:state, :attempts, :result, :requested_revision, :deadline_at)
    sync_assert_enqueued_once(jobs, sync)
    assert_equal 'completed', sync_execute(sync)
    assert_equal @invoice, sync_coverage['invoice_id']
    assert_equal 1, sync_base_rows.size
  end

  # Grok 4th review: a waiting pending request is re-armed whatever its deadline. Within
  # the deadline the re-arm makes it due now instead of at its next retry slot.
  def test_dispatch_sync_dispatch_completion_rearms_a_waiting_request_within_its_deadline
    sync_fixture(paid: true)
    sync = sync_notice!
    assert_equal 'renewal_pending', sync_execute(sync)
    travel_to NOW + 10
    sync_fact!(type: 'invoice.paid', created: NOW.to_i + 10)
    assert_equal ['pending', 'renewal_pending', NOW + 60], sync.reload.values_at(:state, :result, :next_attempt_at)
    sync_dispatch_rearms(sync)
  end

  # Grok 4th review: a wait shortly before the deadline puts the last retry slot past it.
  # claim! would end that slot in a renewal_pending attention after the dispatch completed,
  # and nothing would resume it. The completion re-arms the request before the deadline.
  def test_dispatch_sync_dispatch_completion_rearms_a_waiting_request_in_its_final_slot
    sync_fixture(paid: true)
    sync = sync_notice!
    deadline = sync.deadline_at
    travel_to deadline - 30
    assert_equal 'renewal_pending', sync_execute(sync)
    assert_equal ['pending', 'renewal_pending', 0, deadline, deadline + 30],
                 sync.reload.values_at(:state, :result, :attempts, :deadline_at, :next_attempt_at)
    travel_to deadline - 20
    sync_fact!(type: 'invoice.paid', created: Time.now.to_i)
    travel_to deadline - 10
    sync_dispatch_rearms(sync)
  end

  # The dispatch completion re-arms the waiting request (attempts 0, a new deadline, due
  # now, one revision more) and enqueues it, which reserves the next enqueue slot. The Sync
  # then applies the coverage once.
  def sync_dispatch_rearms(sync)
    revision = sync.reload.requested_revision
    jobs = ActiveJob::Base.queue_adapter.enqueued_jobs
    jobs.clear
    assert_equal 'idle', dispatch_real_execute
    assert_equal 'paid_ready', dispatch_row.phase
    now = Time.now.utc
    assert_equal ['pending', 0, nil, revision + 1, now + Reconciliation::DEADLINE, now, now + 60],
                 sync.reload.values_at(:state, :attempts, :result, :requested_revision, :deadline_at, :next_attempt_at, :next_enqueue_at)
    sync_assert_enqueued_once(jobs, sync)
    assert_equal 'completed', sync_execute(sync)
    assert_equal ['completed', 'applied', revision + 1], sync.reload.values_at(:state, :result, :completed_revision)
    assert_equal [@invoice, @sync_period.first], sync_coverage.values_at('invoice_id', 'term_start')
    assert_equal 1, sync_base_rows.size
  end

  # An expired pending request behind a real failure is not re-armed; claim! ends it.
  def test_dispatch_sync_dispatch_completion_leaves_an_expired_real_failure_to_claim
    sync_fixture(paid: true)
    sync = sync_notice!
    travel_to NOW + 600
    sync_fact!(type: 'invoice.paid', created: NOW.to_i + 600)
    sync.update_columns(result: 'processing_unavailable')
    travel_to sync.reload.deadline_at + 60
    revision = sync.requested_revision
    deadline = sync.deadline_at
    assert_equal 'idle', dispatch_real_execute
    assert_equal 'paid_ready', dispatch_row.phase
    assert_equal ['pending', 'processing_unavailable', 0, revision, deadline],
                 sync.reload.values_at(:state, :result, :attempts, :requested_revision, :deadline_at)
    assert_equal 'attention', sync_execute(sync)
    assert_equal %w[attention retry_limit], sync.reload.values_at(:state, :result)
  end

  # Grok 5th [high] (a): a claim whose worker crashed leaves the row running, and the
  # dispatch completion finds it running and cannot re-arm it. Past the deadline, claim!
  # (which holds the session lock, so the row is an orphan) re-arms and claims it in one
  # step because the barrier is down, and the Sync completes.
  def test_dispatch_sync_expired_orphaned_claim_is_rearmed_and_claimed_after_the_dispatch
    sync_fixture(paid: true)
    sync = sync_notice!
    travel_to NOW + 600
    sync_fact!(type: 'invoice.paid', created: NOW.to_i + 600)
    sync.reload.update_columns(state: 'running', attempts: 1, next_attempt_at: Time.now.utc + 60)
    assert_equal 'idle', dispatch_real_execute
    assert_equal ['paid_ready', 'running', nil], [dispatch_row.phase, sync.reload.state, sync.result]
    revision = sync.requested_revision
    travel_to sync.deadline_at + 120
    assert_equal 'completed', sync_execute(sync)
    assert_equal ['completed', 'applied', 1, Time.now.utc + Reconciliation::DEADLINE, revision],
                 sync.reload.values_at(:state, :result, :attempts, :deadline_at, :completed_revision)
    assert_equal [@invoice, @sync_period.first], sync_coverage.values_at('invoice_id', 'term_start')
    assert_equal 1, sync_base_rows.size
  end

  # The orphan rule re-checks the barrier inside the row lock: a grace due crossed between
  # the pre-claim check and claim! keeps the expired orphan in a renewal_pending attention.
  def test_dispatch_sync_orphan_reclaim_rechecks_the_barrier_in_the_row_lock
    sync_fixture(paid: false)
    sync_fact!(type: 'invoice.payment_failed', created: NOW.to_i - 30)
    assert_equal 'idle', dispatch_real_execute
    due = dispatch_row.due_at
    sync = sync_notice!
    sync.update_columns(state: 'running', attempts: 1, result: nil, next_attempt_at: due - 10, deadline_at: due - 10)
    travel_to due - 1
    refute Dispatch.blocked?('test', @sub, now: Time.now.utc)
    due_check = Reconciliation.method(:due?)
    crossing = lambda do |record, _at|
      travel_to due + 1
      due_check.call(record, Time.now.utc)
    end
    result = Reconciliation.stub(:due?, crossing) { Reconciliation::Execution.new(sync, client: sync_unreachable).call }
    assert_equal 'attention', result
    assert_equal ['attention', 'renewal_pending', 1], sync.reload.values_at(:state, :result, :attempts)
  end

  # A run claimed before the grace due whose provider read crosses both the due and the
  # request deadline: the in-lock guard decides :wait. The block runs right after that
  # decision, before finish!.
  def sync_crossing_expiry
    sync_fixture(paid: false)
    sync_fact!(type: 'invoice.payment_failed', created: NOW.to_i - 30)
    assert_equal 'idle', dispatch_real_execute
    due = dispatch_row.due_at
    sync = sync_notice!
    sync.update_columns(deadline_at: due)
    travel_to due - 5
    test = self
    crossing = Object.new
    crossing.define_singleton_method(:retrieve_subscription) do |_|
      test.travel_to(due + 1)
      test.instance_variable_get(:@subscription).deep_dup
    end
    guard = Dispatch.method(:guard_sync!)
    decide = lambda do |*args, **options|
      guard.call(*args, **options).tap do |decision|
        assert_equal :wait, decision
        yield if block_given?
      end
    end
    [sync, Dispatch.stub(:guard_sync!, decide) { Reconciliation::Execution.new(sync, client: crossing).call }]
  end

  # Grok 5th [high] (b): the barrier lifted after this run's :wait decision and before its
  # expiry. The dispatch needs the same session lock, so only a worker that lost that lock
  # (a dropped connection) sees this; the dispatch completion then found the row running.
  # The row update stands in for that completion. The expiry re-arms instead of attention.
  def test_dispatch_sync_wait_whose_barrier_lifted_before_its_expiry_is_rearmed
    sync, result = sync_crossing_expiry { dispatch_row.update_columns(state: 'idle', phase: 'paid_ready') }
    assert_equal 'renewal_pending', result
    now = Time.now.utc
    assert_equal ['pending', 0, nil, now + Reconciliation::DEADLINE, now, now],
                 sync.reload.values_at(:state, :attempts, :result, :deadline_at, :next_attempt_at, :next_enqueue_at)
  end

  # Grok 5th [high] (c): with the barrier still up at the expiry the wait ends in a
  # renewal_pending attention, which the dispatch completion re-arms (rearm_waiting!, as
  # enqueue_sync! does in test_dispatch_sync_in_lock_wait_attention_is_rearmed_by_the_dispatch_completion).
  def test_dispatch_sync_wait_expiring_behind_the_barrier_is_left_to_the_dispatch_completion
    sync, result = sync_crossing_expiry
    assert_equal 'attention', result
    assert_equal ['attention', 'renewal_pending', 0], sync.reload.values_at(:state, :result, :attempts)
    assert Reconciliation.rearm_waiting!(sync, now: Time.now.utc)
    assert_equal ['pending', 0, nil], sync.reload.values_at(:state, :attempts, :result)
  end

  # A status-only wait never had the barrier up (here no dispatch row yet: the N1 fact has
  # not arrived). Its expiry during the run still ends in attention, so a missing N1 stays
  # visible instead of re-arming at every deadline.
  def test_dispatch_sync_status_only_wait_expiring_during_the_run_ends_in_attention
    sync_fixture(paid: true)
    sync = sync_notice!
    sync.update_columns(deadline_at: Time.now.utc + 1)
    deadline = sync.deadline_at
    test = self
    crossing = Object.new
    crossing.define_singleton_method(:retrieve_subscription) do |_|
      test.travel_to(deadline + 1)
      test.instance_variable_get(:@subscription).deep_dup
    end
    assert_equal 'attention', Reconciliation::Execution.new(sync, client: crossing).call
    refute Dispatch.blocked?('test', @sub, now: Time.now.utc)
    assert_equal ['attention', 'renewal_pending', 0], sync.reload.values_at(:state, :result, :attempts)
    assert_equal ['active', false], @account.reload.internal_attributes.values_at(*SYNC_STATUS_FIELDS)
  end

  # An expired pending wait is not re-armed by claim! either, even with the barrier down:
  # the dispatch completion re-arms pending rows, and without it the attention is the signal.
  def test_dispatch_sync_expired_pending_wait_without_a_barrier_is_not_reclaimed
    sync_fixture(paid: true)
    sync = sync_notice!
    assert_equal 'renewal_pending', sync_execute(sync)
    travel_to sync.reload.deadline_at + 60
    refute Dispatch.blocked?('test', @sub, now: Time.now.utc)
    assert_equal 'attention', sync_execute(sync, client: sync_unreachable)
    assert_equal ['attention', 'renewal_pending', 0], sync.reload.values_at(:state, :result, :attempts)
  end

  # A real failure at the deadline is never re-armed by the expiry: a run failing with
  # writer_busy keeps that result, and an orphaned claim behind a real failure expires as
  # retry_limit without a provider read.
  def test_dispatch_sync_real_failure_at_the_deadline_is_not_rearmed_by_the_expiry
    sync_fixture(paid: true)
    sync = sync_notice!
    sync.update_columns(deadline_at: Time.now.utc + 1)
    deadline = sync.deadline_at
    test = self
    busy = Object.new
    busy.define_singleton_method(:retrieve_subscription) do |_|
      test.travel_to(deadline + 1)
      raise Toybaco::Growth::InboxRetention::Busy
    end
    assert_equal 'attention', Reconciliation::Execution.new(sync, client: busy).call
    assert_equal ['attention', 'writer_busy', 1], sync.reload.values_at(:state, :result, :attempts)
    sync.update_columns(state: 'running', result: 'processing_unavailable', next_attempt_at: Time.now.utc - 1)
    assert_equal 'attention', sync_execute(sync, client: sync_unreachable)
    assert_equal ['attention', 'retry_limit', 1], sync.reload.values_at(:state, :result, :attempts)
  end

  # RenewalIngress#bind_revision! binds the fact's event at acceptance, so an unbound event
  # only stands for legacy or racing rows. Both binding columns clear together (check
  # constraint toybaco_billing_revision_binding).
  def sync_unbind!(receipt)
    Toybaco::BillingEvent.where(id: receipt.id).update_all(subscription_sync_request_id: nil, requested_revision: nil)
  end

  # Grok 6th [high]: for an unbound fact event, BillingSubscription.bind! records the
  # request through persist_request!, whose refresh only bumps the revision of an existing
  # pending row. enqueue_sync! still re-arms the waiting row and enqueues it exactly once
  # (revision +2: the refresh and the re-arm).
  def test_dispatch_sync_unbound_fact_rearms_an_expired_waiting_request
    sync_unbound_rearm(expired: true)
  end

  # The same with the next retry slot still ahead (inside the 60 second slot).
  def test_dispatch_sync_unbound_fact_rearms_a_waiting_request_before_its_next_slot
    sync_unbound_rearm(expired: false)
  end

  def sync_unbound_rearm(expired:)
    sync_fixture(paid: true)
    sync = sync_notice!
    assert_equal 'renewal_pending', sync_execute(sync)
    fact_at = expired ? NOW + 600 : NOW + 10
    travel_to fact_at
    sync_unbind!(sync_fact!(type: 'invoice.paid', created: fact_at.to_i))
    travel_to sync.reload.deadline_at + 60 if expired
    assert_equal ['pending', 'renewal_pending', NOW + 60], sync.reload.values_at(:state, :result, :next_attempt_at)
    assert_operator sync.next_attempt_at, expired ? :< : :>, Time.now.utc
    sync_unbound_dispatch_rearms(sync, sync.requested_revision + 2)
  end

  # An unbound fact event and a wait-caused attention: the refresh in persist_request!
  # re-arms the attention and rearm_waiting! re-arms the pending row once more (revision
  # +2; the revision contract is only monotonic).
  def test_dispatch_sync_unbound_fact_rearms_a_wait_caused_attention
    sync_fixture(paid: true)
    sync = sync_notice!
    assert_equal 'renewal_pending', sync_execute(sync)
    travel_to NOW + 600
    sync_unbind!(sync_fact!(type: 'invoice.paid', created: NOW.to_i + 600))
    travel_to sync.reload.deadline_at + 60
    assert_equal 'attention', sync_execute(sync)
    assert_equal %w[attention renewal_pending], sync.reload.values_at(:state, :result)
    sync_unbound_dispatch_rearms(sync, sync.requested_revision + 2)
  end

  def sync_unbound_dispatch_rearms(sync, revision)
    jobs = ActiveJob::Base.queue_adapter.enqueued_jobs
    jobs.clear
    assert_equal 'idle', dispatch_real_execute
    assert_equal 'paid_ready', dispatch_row.phase
    now = Time.now.utc
    assert_equal ['pending', 0, nil, revision, now + Reconciliation::DEADLINE, now, now + 60],
                 sync.reload.values_at(:state, :attempts, :result, :requested_revision, :deadline_at, :next_attempt_at, :next_enqueue_at)
    sync_assert_enqueued_once(jobs, sync)
    assert_equal 'completed', sync_execute(sync)
    assert_equal [@invoice, @sync_period.first], sync_coverage.values_at('invoice_id', 'term_start')
    assert_equal 1, sync_base_rows.size
  end

  # An unbound fact event without any Sync request row: bind! records a new request (the
  # event binds revision 1), the re-arm moves it to revision 2 and it is enqueued once.
  def test_dispatch_sync_unbound_fact_without_a_request_records_and_enqueues_it_once
    sync_fixture(paid: true)
    receipt = sync_fact!(type: 'invoice.paid', created: NOW.to_i - 10)
    old = receipt.reload.subscription_sync_request_id
    sync_unbind!(receipt)
    Toybaco::SubscriptionSyncRequest.where(id: old).delete_all
    jobs = ActiveJob::Base.queue_adapter.enqueued_jobs
    jobs.clear
    assert_equal 'idle', dispatch_real_execute
    assert_equal 'paid_ready', dispatch_row.phase
    request = Toybaco::SubscriptionSyncRequest.find_by!(subscription_id: @sub)
    refute_equal old, request.id
    now = Time.now.utc
    assert_equal ['pending', 0, nil, 2, now + Reconciliation::DEADLINE, now, now + 60],
                 request.values_at(:state, :attempts, :result, :requested_revision, :deadline_at, :next_attempt_at, :next_enqueue_at)
    assert_equal [request.id, 1], receipt.reload.values_at(:subscription_sync_request_id, :requested_revision)
    sync_assert_enqueued_once(jobs, request)
    assert_equal 'completed', sync_execute(request)
    assert_equal 1, sync_base_rows.size
  end
end
