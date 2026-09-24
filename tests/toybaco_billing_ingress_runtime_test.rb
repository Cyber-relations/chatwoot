# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/mock'
require 'active_support/testing/time_helpers'
require Rails.root.join('lib/toybaco/growth/billing_receipt')
require Rails.root.join('lib/toybaco/growth/billing_execution')
require Rails.root.join('app/jobs/toybaco/growth_payment_sweep_job')

class ToybacoBillingIngressRuntimeTest < Minitest::Test
  include ActiveSupport::Testing::TimeHelpers
  Growth = Toybaco::Growth
  NOW = Time.utc(2026, 9, 24, 8)

  def setup
    @previous = ENV.to_h.slice('TOYBACO_STRIPE_MODE', 'TOYBACO_BILLING_INGRESS_ENABLED')
    ENV.update('TOYBACO_STRIPE_MODE' => 'test', 'TOYBACO_BILLING_INGRESS_ENABLED' => 'true')
    @adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @events, @requests = [], []
    travel_to NOW
  end

  def teardown
    Toybaco::BillingEvent.where(id: @events).delete_all
    Toybaco::SubscriptionSyncRequest.where(id: @requests).delete_all
    %w[TOYBACO_STRIPE_MODE TOYBACO_BILLING_INGRESS_ENABLED].each { |key| @previous.key?(key) ? ENV[key] = @previous[key] : ENV.delete(key) }
    ActiveJob::Base.queue_adapter = @adapter
    travel_back
  end

  def event(type: 'customer.subscription.updated', reference: "sub_#{SecureRandom.hex(8)}", id: "evt_#{SecureRandom.hex(8)}")
    object = { 'id' => reference, 'object' => 'subscription', 'status' => 'stale', 'private' => 'never retain' }
    if type == 'checkout.session.completed'
      object = { 'id' => reference, 'object' => 'checkout.session', 'mode' => 'subscription',
                 'metadata' => { 'toybaco_existing_account_id' => '123', 'toybaco_purchase_nonce' => 'never retain' },
                 'customer_details' => { 'email' => 'never-retain@example.invalid' }, 'payment_status' => 'unpaid' }
    end
    { 'id' => id, 'object' => 'event', 'type' => type, 'livemode' => false, 'created' => NOW.to_i, 'data' => { 'object' => object } }
  end

  def accept(value = event)
    attrs = Growth::BillingSnapshot.new(value).read
    row = Growth::BillingReceipt.accept!(attrs)
    @events << row.id
    row
  end

  def accept_subscription(row)
    request = Growth::BillingSubscription.accept!(row)
    @requests << request.id
    request
  end

  def test_minimal_committed_receipt_is_idempotent_and_does_not_extend_deadline
    value = event
    row = accept(value)
    travel_to NOW + 3600
    again = accept(value)
    assert_equal row.id, again.id
    assert_equal [NOW + 86_400, 0], [again.deadline_at, again.attempts]
    assert_equal({ 'subscription' => value.dig('data', 'object', 'id') }, again.snapshot.dig('data', 'object'))
    refute_includes again.snapshot.to_json, 'never retain'
  end

  def test_event_conflict_wrong_mode_future_and_duplicate_json_fail_closed
    row = accept
    conflict = event(reference: row.reference_id, id: row.event_id)
    conflict['type'] = 'customer.subscription.deleted'
    assert_raises(Growth::BillingReceipt::Conflict) { accept(conflict) }
    [event.merge('livemode' => true), event.merge('created' => NOW.to_i + 1), event.merge('account' => 'acct_other')].each do |value|
      assert_raises(Growth::PaymentSignature::Invalid) { Growth::BillingSnapshot.new(value).read }
    end
    raw = '{"id":"evt_one","id":"evt_two"}'
    secret = 'whsec_fixture12345678901234567890'
    signature = "t=#{NOW.to_i},v1=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "#{NOW.to_i}.#{raw}")}"
    assert_raises(Growth::PaymentSignature::Invalid) do
      Growth::PaymentSignature.verify!(raw, signature, environment: { 'TOYBACO_STRIPE_PACK_WEBHOOK_SECRET' => secret })
    end
  end

  def test_invoice_can_also_have_an_independent_existing_payment_receipt
    value = event(type: 'invoice.payment_failed')
    value['data']['object'] = { 'object' => 'invoice', 'subscription' => 'sub_invoice', 'id' => 'in_invoice' }
    row = accept(value)
    payment = Toybaco::GrowthPaymentEvent.create!(event_id: row.event_id, action: 'renewal_failure', reference_id: 'in_invoice',
      snapshot: { 'fixture' => true }, payload_digest: 'a' * 64, next_attempt_at: NOW)
    assert_equal 'subscription_notice', row.action
    assert_equal row.event_id, payment.event_id
  ensure
    payment&.destroy!
  end

  def test_receipt_and_subscription_admission_reject_outer_transaction
    row = accept
    Account.transaction do
      assert_raises(Growth::BillingReceipt::Conflict) { accept }
      assert_raises(Toybaco::SubscriptionReconciliation::Invalid) { accept_subscription(row) }
      assert_raises(Toybaco::SubscriptionReconciliation::Invalid) { Growth::BillingExecution.new(row).call }
    end
  end

  def test_ack_loss_after_revision_commit_reuses_mapping_without_refresh_or_budget_reset
    row = accept
    request = accept_subscription(row)
    assert_equal [request.id, 1], [row.reload.subscription_sync_request_id, row.requested_revision]
    deadline = request.deadline_at
    request.update!(state: 'completed', completed_revision: 1, completed_at: NOW, attempts: 7)
    travel_to NOW + 7200
    again = accept_subscription(row)
    assert_equal [request.id, 1, 7, deadline, 'completed'],
      [again.id, again.requested_revision, again.attempts, again.deadline_at, again.state]
  end

  def test_failure_after_revision_update_before_event_mapping_rolls_back_both
    first = accept
    request = accept_subscription(first)
    second = accept(event(reference: first.reference_id))
    second.stub(:update!, ->(*) { raise IOError, 'fixture mapping write failure' }) do
      assert_raises(IOError) { accept_subscription(second) }
    end
    assert_equal 1, request.reload.requested_revision
    assert_nil second.reload.subscription_sync_request_id
    assert_equal 2, accept_subscription(second).requested_revision
  end

  def test_failure_after_new_request_insert_does_not_leave_an_unmapped_request
    row = accept
    row.stub(:update!, ->(*) { raise IOError, 'fixture mapping write failure' }) do
      assert_raises(IOError) { accept_subscription(row) }
    end
    refute Toybaco::SubscriptionSyncRequest.exists?(subscription_id: row.reference_id)
    assert_equal 1, accept_subscription(row).requested_revision
  end

  def test_distinct_event_during_running_creates_next_revision_but_does_not_extend_retry_budget
    row = accept
    request = accept_subscription(row)
    request.update!(state: 'running', attempts: 47)
    other = accept(event(reference: row.reference_id))
    travel_to NOW + 86_000
    next_request = accept_subscription(other)
    assert_equal [2, 47, NOW + 86_400], [next_request.requested_revision, next_request.attempts, next_request.deadline_at]
    request.update!(state: 'attention', result: 'retry_limit')
    last = accept(event(reference: row.reference_id))
    assert_equal [2, 'attention'], [accept_subscription(last).requested_revision, request.reload.state]
  end

  def test_queue_ack_loss_and_flag_off_are_recovered_without_a_new_cron
    row = accept
    jobs = []
    Toybaco::BillingEventJob.stub(:perform_later, ->(id) { jobs << id; raise ActiveJob::EnqueueError }) do
      Growth::BillingReceipt.enqueue(row)
    end
    assert_equal [row.id], jobs
    assert_equal 'pending', row.reload.state
    ENV['TOYBACO_BILLING_INGRESS_ENABLED'] = 'false'
    travel_to NOW + 61
    Toybaco::GrowthPaymentSweepJob.perform_now
    queued = ActiveJob::Base.queue_adapter.enqueued_jobs.select { |entry| entry[:job] == Toybaco::BillingEventJob }
    assert_equal [row.id], queued.flat_map { |entry| entry[:args] }
  end

  def test_subscription_worker_uses_durable_mapping_and_reports_admission_not_business_completion
    row = accept
    Growth::BillingExecution.new(row).call
    @requests << row.reload.subscription_sync_request_id
    assert_equal ['completed', 'subscription_accepted'], [row.state, row.result]
    request = Toybaco::SubscriptionSyncRequest.find(row.subscription_sync_request_id)
    assert_equal ['pending', 0], [request.state, request.completed_revision]
    Growth::BillingExecution.new(row).call
    assert_equal 1, request.reload.requested_revision
  end

  def test_checkout_pending_is_retried_and_only_verified_complete_is_finished
    row = accept(event(type: 'checkout.session.completed', reference: 'cs_test_ingress'))
    service = Object.new
    service.define_singleton_method(:complete!) { |_| 'payment_pending' }
    Growth::PurchaseFulfillment.stub(:new, service) { Growth::BillingExecution.new(row, client: Object.new).call }
    assert_equal ['pending', 1], [row.reload.state, row.attempts]
    refute_includes row.snapshot.to_json, 'never-retain'
    travel_to row.next_attempt_at
    service.define_singleton_method(:complete!) { |_| 'complete' }
    Growth::PurchaseFulfillment.stub(:new, service) { Growth::BillingExecution.new(row, client: Object.new).call }
    assert_equal ['completed', 'checkout_complete', 2], [row.reload.state, row.result, row.attempts]
  end

  def test_changed_mode_and_corrupt_reference_never_reach_provider
    row = accept
    ENV['TOYBACO_STRIPE_MODE'] = 'live'
    Growth::BillingExecution.new(row).call
    assert_equal ['attention', 'payment_mismatch'], [row.reload.state, row.result]
    assert_nil row.subscription_sync_request_id
  end

  def test_expired_processing_is_recovered_and_duplicate_event_does_not_reset_attention
    row = accept
    row.update!(state: 'processing', attempts: 47, lease_token: 'fixture', lease_expires_at: NOW - 1)
    travel_to NOW + 86_400
    Growth::BillingExecution.new(row).call
    assert_equal ['attention', 'retry_limit'], [row.reload.state, row.result]
    again = accept(event(reference: row.reference_id, id: row.event_id))
    assert_equal [row.id, 47, NOW + 86_400, 'attention'], [again.id, again.attempts, again.deadline_at, again.state]
  end

  def test_worker_death_on_last_attempt_and_corrupt_snapshot_fail_closed
    row = accept
    row.update!(state: 'processing', attempts: 48, lease_token: 'fixture', lease_expires_at: NOW - 1)
    Growth::BillingExecution.new(row).call
    assert_equal ['attention', 48, 'retry_limit'], [row.reload.state, row.attempts, row.result]
    corrupt = accept
    Toybaco::BillingEvent.connection.execute("UPDATE toybaco_billing_events SET payload_digest = '#{'0' * 64}' WHERE id = #{corrupt.id}")
    Growth::BillingExecution.new(corrupt.reload).call
    assert_equal ['attention', 'payment_mismatch'], [corrupt.reload.state, corrupt.result]
  end

  def test_database_rejects_half_mapping_and_preserves_the_referenced_request
    row = accept
    request = accept_subscription(row)
    assert_raises(ActiveRecord::StatementInvalid) do
      Toybaco::BillingEvent.connection.execute("UPDATE toybaco_billing_events SET requested_revision = NULL WHERE id = #{row.id}")
    end
    assert_equal [request.id, 1], [row.reload.subscription_sync_request_id, row.requested_revision]
    assert_raises(ActiveRecord::InvalidForeignKey) { request.destroy! }
    assert_equal row.id, Toybaco::BillingEvent.find(row.id).id
  end

  def test_independent_connections_accept_same_event_once_and_one_revision
    row = accept
    ids = Queue.new
    errors = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          current = Toybaco::BillingEvent.find(row.id)
          ids << Growth::BillingSubscription.accept!(current).id
        end
      rescue StandardError => error
        errors << error
      end
    end
    threads.each(&:join)
    raise errors.pop unless errors.empty?
    first, second = ids.pop, ids.pop
    @requests << first
    assert_equal first, second
    assert_equal 1, Toybaco::SubscriptionSyncRequest.find(first).requested_revision
    assert_equal 1, row.reload.requested_revision
  end
end
