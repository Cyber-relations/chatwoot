# frozen_string_literal: true

require Rails.root.join('lib/toybaco/growth/renewal_dispatch_execution')
require Rails.root.join('lib/toybaco/subscription_reconciliation/execution')

module ToybacoGrowthRenewalDispatchCases
  Growth = Toybaco::Growth
  NOW = Time.utc(2026, 9, 24, 8)
  Dispatch = Toybaco::Growth::RenewalDispatch

  def setup
    @dispatch_flag = ENV[Dispatch::FLAG]
    ENV[Dispatch::FLAG] = name.start_with?('test_dispatch_') ? 'true' : 'false'
    super
  end

  def teardown
    ids = Toybaco::RenewalOperation.where(subscription_id: @sub).pluck(:id)
    Toybaco::GrowthRenewalDispatch.where(renewal_operation_id: ids).delete_all
    @dispatch_flag.nil? ? ENV.delete(Dispatch::FLAG) : ENV[Dispatch::FLAG] = @dispatch_flag
    super
  end

  def dispatch_row
    Toybaco::GrowthRenewalDispatch.find_by!(renewal_operation_id: operation.id)
  end

  def dispatch_execute(worker, at: Time.now.utc)
    Growth::RenewalDispatchExecution.new(dispatch_row, clock: -> { at }, worker: worker).call
  end

  def test_dispatch_acceptance_revision_fact_and_marker_share_rollback
    Toybaco::GrowthRenewalDispatch.stub(:create!, ->(*) { raise IOError }) do
      assert_raises(IOError) { accept }
    end
    refute Toybaco::RenewalOperation.exists?(subscription_id: @sub)
    refute Toybaco::SubscriptionSyncRequest.exists?(subscription_id: @sub)
    event = accept
    assert_equal ['pending', 'received', 0], dispatch_row.values_at(:state, :phase, :processed_fact_id)
    assert_equal event.id, Toybaco::RenewalInvoiceFact.find(dispatch_row.requested_fact_id).billing_event_id
  end

  # Before N3 the barrier admits only the status-only Sync (while the row is still
  # 'received' and N2 has not started): no contract write and no retry budget spent.
  def test_dispatch_barrier_allows_only_status_only_sync_before_n3
    event = accept
    sync = Toybaco::SubscriptionSyncRequest.find(event.subscription_sync_request_id)
    contract = @account.reload.internal_attributes['toybaco_contract']
    assert_equal 'renewal_pending', Toybaco::SubscriptionReconciliation::Execution.new(sync, client: @client, now: NOW).call
    assert_equal [0, 'pending', 0, 'renewal_pending'], sync.reload.values_at(:attempts, :state, :completed_revision, :result)
    assert_equal ['past_due', contract], @account.reload.internal_attributes.values_at('toybaco_subscription_status', 'toybaco_contract')
    assert Dispatch.blocked?('test', @sub, now: NOW)
  end

  def test_dispatch_old_subscription_session_rejects_admission_before_ack
    event_value = event
    # The fixed gate database requires a password; the second session must authenticate like the first.
    db = PG.connect(Account.connection.raw_connection.conninfo_hash.slice(:host, :port, :dbname, :user, :password))
    key = Dispatch.lock_key('test', @sub)
    db.exec("SELECT pg_advisory_lock(#{key})")
    assert_raises(Dispatch::Busy) { accept(event_value) }
    refute Toybaco::BillingEvent.exists?(event_id: event_value['id'])
    refute Toybaco::SubscriptionSyncRequest.exists?(subscription_id: @sub)
    db.exec("SELECT pg_advisory_unlock(#{key})")
    assert accept(event_value)
  ensure
    db&.close
  end

  def test_dispatch_billing_worker_only_acknowledges_durable_acceptance
    event = accept
    Growth::BillingExecution.new(event, client: @client, now: NOW).call
    assert_equal ['completed', 'renewal_dispatch_accepted'], event.reload.values_at(:state, :result)
    assert_nil operation.account_id
    assert_equal 'pending', dispatch_row.state
    jobs = ActiveJob::Base.queue_adapter.enqueued_jobs
    assert jobs.any? { |job| job[:job] == Toybaco::GrowthRenewalDispatchJob && job[:args] == [dispatch_row.id] }
  end

  def test_dispatch_queue_response_loss_retains_reservation_and_flag_off_recovery
    accept
    row = dispatch_row
    Toybaco::GrowthRenewalDispatchJob.stub(:perform_later, ->(*) { raise IOError }) do
      assert_nil Growth::RenewalDispatchQueue.enqueue(row, now: NOW)
    end
    assert_equal NOW + 60, row.reload.next_enqueue_at
    ENV[Dispatch::FLAG] = 'false'
    refute_nil Growth::RenewalDispatchQueue.enqueue(row, now: NOW + 60)
    assert_equal 'idle', dispatch_execute(-> { 'paid_ready' }, at: NOW + 60)
    refute Dispatch.blocked?('test', @sub, now: NOW + 60)
    other = event
    other['data']['object']['id'] = 'in_unaccepted'
    accept(other)
    assert_equal 1, Toybaco::GrowthRenewalDispatch.joins('JOIN toybaco_renewal_operations o ON o.id=renewal_operation_id').where('o.subscription_id = ?', @sub).count
  end

  def test_dispatch_grace_due_is_fixed_and_unknown_never_becomes_complete
    accept
    due = operation.due_at
    assert_equal 'idle', dispatch_execute(-> { 'grace_ready' })
    assert_equal [due, due + Dispatch::DEADLINE], dispatch_row.values_at(:next_attempt_at, :deadline_at)
    refute Dispatch.blocked?('test', @sub, now: due - 1)
    assert Dispatch.blocked?('test', @sub, now: due)
    assert_equal 'pending', dispatch_execute(-> { 'due_waiting' }, at: due)
    assert_equal ['pending', 'due_waiting'], dispatch_row.values_at(:state, :phase)
    dispatch_execute(-> { raise IOError }, at: due + Dispatch::DEADLINE)
    assert_equal ['attention', 'retry_limit'], dispatch_row.values_at(:state, :result)
    assert Dispatch.blocked?('test', @sub, now: due + 2 * Dispatch::DEADLINE)
  end

  def test_dispatch_same_invoice_replay_cannot_rearm_paid_continuation
    first = accept
    assert_equal 'idle', dispatch_execute(-> { 'paid_ready' })
    accept(event(attempt: 2))
    row = dispatch_row
    assert_equal ['idle', 'paid_ready'], row.values_at(:state, :phase)
    assert_equal row.requested_fact_id, row.processed_fact_id
    assert_equal first.id, accept(first.snapshot).id
    dispatch_execute(-> { raise 'terminal request must not run twice' })
    assert_equal 'idle', row.reload.state
  end

  def test_dispatch_expired_queue_lease_cannot_start_a_second_live_worker
    accept
    row = dispatch_row
    entered = Queue.new
    release = Queue.new
    calls = 0
    thread = Thread.new do
      Account.connection_pool.with_connection do
        worker = -> { calls += 1; entered << true; release.pop; 'paid_ready' }
        Growth::RenewalDispatchExecution.new(Toybaco::GrowthRenewalDispatch.find(row.id), clock: -> { NOW }, worker: worker).call
      end
    end
    entered.pop
    assert_equal 'busy', dispatch_execute(-> { calls += 1; 'paid_ready' }, at: NOW + 301)
    assert_equal 1, calls
    release << true
    assert_equal 'idle', thread.value
    assert_equal 'paid_ready', row.reload.phase
  ensure
    release << true if release && thread&.alive?
    thread&.join
  end

  def test_dispatch_marker_survives_receipt_and_account_deletion
    accept
    id = dispatch_row.id
    marker = Account.connection.select_value("SELECT accepted_at FROM toybaco_durable_capability_acceptances WHERE capability='renewal-dispatch-v1'")
    refute_nil marker
    Toybaco::GrowthRenewalDispatch.find(id).delete
    @account.destroy!
    assert_equal marker, Account.connection.select_value("SELECT accepted_at FROM toybaco_durable_capability_acceptances WHERE capability='renewal-dispatch-v1'")
    assert_raises(ActiveRecord::StatementInvalid) do
      Account.connection.execute("DELETE FROM toybaco_durable_capability_acceptances WHERE capability='renewal-dispatch-v1'")
    end
  end

  def test_dispatch_later_failure_does_not_extend_expired_due_budget
    accept
    due = operation.due_at
    dispatch_execute(-> { 'grace_ready' })
    travel_to due + Dispatch::DEADLINE + 10
    accept(event(attempt: 2))
    assert_equal due + Dispatch::DEADLINE, dispatch_row.deadline_at
    assert_equal 'attention', dispatch_execute(-> { raise 'expired work cannot start' }, at: Time.now.utc)
    assert Dispatch.blocked?('test', @sub, now: Time.now.utc)
  end

  def test_dispatch_outer_transaction_and_context_mutation_are_rejected
    accept
    Account.transaction do
      assert_raises(Dispatch::Invalid) { dispatch_execute(-> { 'paid_ready' }) }
      assert_raises(Dispatch::Invalid) { Growth::RenewalDispatchQueue.enqueue(dispatch_row) }
    end
    row = dispatch_row
    row.update!(paid_context: { 'fixture' => true })
    assert_raises(ActiveRecord::ReadOnlyRecord) { row.update!(paid_context: { 'fixture' => false }) }
    assert_equal true, row.reload.paid_context['fixture']
  end
end
