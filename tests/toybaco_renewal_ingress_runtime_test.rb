# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/mock'
require 'active_support/testing/time_helpers'
require Rails.root.join('lib/toybaco/growth/billing_receipt')
require Rails.root.join('lib/toybaco/growth/billing_execution')

class ToybacoRenewalIngressRuntimeTest < Minitest::Test
  include ActiveSupport::Testing::TimeHelpers
  Growth = Toybaco::Growth
  NOW = Time.utc(2026, 9, 24, 8)
  SECRET = 'whsec_fixture12345678901234567890'

  def setup
    @settings = ENV.to_h.slice('TOYBACO_STRIPE_MODE', 'TOYBACO_BILLING_INGRESS_ENABLED')
    ENV.update('TOYBACO_STRIPE_MODE' => 'test', 'TOYBACO_BILLING_INGRESS_ENABLED' => 'true')
    @adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    travel_to NOW
    suffix = SecureRandom.hex(8)
    @sub, @invoice, @customer = "sub_#{suffix}", "in_#{suffix}", "cus_#{suffix}"
    terms = Toybaco::PlanCatalog.default.definition('standard', '2026-09-18.1')
    contract = Toybaco::Entitlements.snapshot_for(terms, cycle: 'month').merge('stripe_price_id' => 'price_renewal', 'subscription_item_id' => 'si_renewal')
    @account = Account.create!(name: 'Renewal fixture', locale: 'ja', internal_attributes: {
      'toybaco_contract' => contract, 'toybaco_subscription_id' => @sub, 'toybaco_stripe_customer_id' => @customer
    })
    @subscription = { 'id' => @sub, 'customer' => @customer, 'livemode' => false, 'status' => 'past_due',
      'items' => { 'has_more' => false, 'data' => [{ 'id' => 'si_renewal', 'quantity' => 1, 'price' => { 'id' => 'price_renewal' },
        'current_period_start' => NOW.to_i - 3600, 'current_period_end' => (NOW + 30.days).to_i }] },
      'latest_invoice' => { 'id' => @invoice, 'status' => 'open', 'currency' => 'jpy', 'billing_reason' => 'subscription_cycle',
        'subscription' => @sub, 'amount_remaining' => 19_800 } }
    owner = self
    @client = Object.new
    @client.define_singleton_method(:retrieve_subscription) { |_| owner.instance_variable_get(:@subscription).deep_dup }
  end

  def teardown
    operations = Toybaco::RenewalOperation.where(subscription_id: @sub)
    operations.update_all(first_fact_id: nil, first_failed_at: nil, due_at: nil, state: 'unverified')
    Toybaco::RenewalInvoiceFact.where(subscription_id: @sub).delete_all
    operations.delete_all
    Toybaco::BillingEvent.where(reference_id: @sub).delete_all
    Toybaco::SubscriptionSyncRequest.where(subscription_id: @sub).delete_all
    @account&.destroy! if @account&.persisted?
    %w[TOYBACO_STRIPE_MODE TOYBACO_BILLING_INGRESS_ENABLED].each { |key| @settings.key?(key) ? ENV[key] = @settings[key] : ENV.delete(key) }
    ActiveJob::Base.queue_adapter = @adapter
    travel_back
  end

  def event(attempt: 1, type: 'invoice.payment_failed', created: NOW.to_i - 30)
    { 'id' => "evt_#{SecureRandom.hex(10)}", 'object' => 'event', 'type' => type, 'livemode' => false, 'created' => created,
      'data' => { 'object' => { 'object' => 'invoice', 'id' => @invoice, 'customer' => @customer,
        'parent' => { 'subscription_details' => { 'subscription' => @sub } }, 'billing_reason' => 'subscription_cycle', 'attempt_count' => attempt,
        'customer_email' => 'do-not-retain@example.invalid', 'metadata' => { 'private' => 'never save' } } } }
  end

  def accept(value = event)
    raw = JSON.generate(value)
    header = "t=#{Time.now.to_i},v1=#{OpenSSL::HMAC.hexdigest('SHA256', SECRET, "#{Time.now.to_i}.#{raw}")}"
    verified = Growth::PaymentSignature.verify!(raw, header, environment: { 'TOYBACO_STRIPE_PACK_WEBHOOK_SECRET' => SECRET })
    Growth::BillingReceipt.accept!(Growth::BillingSnapshot.new(verified).read)
  end

  # The first-created operation; an unordered find_by! followed heap order once a
  # second invoice of the same subscription existed.
  def operation = Toybaco::RenewalOperation.where(subscription_id: @sub).order(:id).first!
  def failure = @account.reload.internal_attributes[Growth::RenewalFailureReceipt::KEY]
  def verify(row) = Growth::RenewalIngressVerification.new(row, client: @client, now: Time.now.utc).record!

  def test_signature_fact_revision_and_due_operation_commit_together_without_business_effect
    value = event
    row = accept(value)
    fact = Toybaco::RenewalInvoiceFact.find_by!(billing_event_id: row.id)
    request = Toybaco::SubscriptionSyncRequest.find(row.subscription_sync_request_id)
    assert_equal [value['id'], @invoice, @sub, @customer, 'test', 1], fact.values_at(:event_id, :invoice_id, :subscription_id, :customer_id, :mode, :attempt_count)
    assert_equal [1, 1], [row.requested_revision, request.requested_revision]
    assert_equal ['unverified', Time.at(value['created']), Time.at(value['created'] + 7.days)],
      [operation.state, operation.first_failed_at, operation.due_at]
    assert_nil failure
    refute_includes [fact.attributes, row.snapshot].to_json, 'do-not-retain'
    refute_includes [fact.attributes, row.snapshot].to_json, 'never save'
  end

  def test_first_failure_uses_the_same_minimal_fact_as_the_older_webhook
    value = event
    old = Growth::PaymentSnapshot.new(value).read
    current = Growth::BillingSnapshot.new(value).read
    assert_equal old[:snapshot], current[:snapshot]
    assert_equal ['renewal_failure', 'subscription_notice'], [old[:action], current[:action]]
    row = accept(value)
    assert_equal 'first_failure_recorded', verify(row)
    assert_equal [value['created'], value['created'] + 7.days], failure.values_at('first_failed_at', 'grace_ends_at')
    assert_equal ['observed_failure', @account.id], [operation.state, operation.account_id]
    assert_match(/\A[0-9a-f]{64}\z/, operation.source_hash)
  end

  def test_replay_after_worker_commit_and_days_passed_cannot_extend_either_deadline_or_revision
    value = event
    row = accept(value)
    verify(row)
    before = operation.attributes
    travel_to NOW + 3.days
    assert_equal row.id, accept(value).id
    assert_equal before, operation.attributes
    assert_equal [1, NOW + 86_400], [row.reload.requested_revision, row.deadline_at]
    assert_equal 1, Toybaco::RenewalInvoiceFact.where(subscription_id: @sub).count
  end

  def test_fact_insert_failure_rolls_back_event_operation_and_subscription_revision
    value = event
    Toybaco::RenewalInvoiceFact.stub(:create!, ->(*) { raise IOError, 'fixture insert failure' }) do
      assert_raises(IOError) { accept(value) }
    end
    refute Toybaco::BillingEvent.exists?(event_id: value['id'])
    refute Toybaco::RenewalOperation.exists?(subscription_id: @sub)
    refute Toybaco::SubscriptionSyncRequest.exists?(subscription_id: @sub)
    assert_equal 1, accept(value).requested_revision
  end

  def test_second_event_insert_failure_rolls_back_revision_increment
    first = accept
    Toybaco::RenewalInvoiceFact.stub(:create!, ->(*) { raise IOError }) { assert_raises(IOError) { accept(event(attempt: 2)) } }
    assert_equal 1, Toybaco::SubscriptionSyncRequest.find(first.subscription_sync_request_id).requested_revision
    assert_equal 1, Toybaco::RenewalInvoiceFact.where(subscription_id: @sub).count
  end

  def test_operation_failure_after_account_write_rolls_back_both
    row = accept
    hook = -> { raise IOError, 'fixture after operation write' if state == 'observed_failure' }
    Toybaco::RenewalOperation.set_callback(:update, :after, hook)
    assert_raises(IOError) { verify(row) }
    assert_nil failure
    assert_equal ['unverified', nil], [operation.state, operation.account_id]
  ensure
    Toybaco::RenewalOperation.skip_callback(:update, :after, hook) if hook
  end

  def test_later_attempt_first_does_not_invent_origin_and_earlier_signed_fact_can_only_shorten
    later = accept(event(attempt: 3))
    assert_nil operation.first_failed_at
    assert_equal 'awaiting_first_failure', verify(later)
    assert_nil failure
    first = accept(event(created: NOW.to_i - 60))
    verify(first)
    due = operation.due_at
    verify(accept(event(created: NOW.to_i - 20)))
    assert_equal due, operation.due_at
    earlier = accept(event(created: NOW.to_i - 120))
    verify(earlier)
    assert_equal NOW - 120 + 7.days, operation.due_at
    assert_equal NOW.to_i - 120, failure['first_failed_at']
  end

  def test_following_attempt_preserves_verified_origin_instead_of_waiting_for_it_again
    first = accept
    verify(first)
    due = operation.due_at
    later = accept(event(attempt: 3))
    assert_equal 'first_failure_already_recorded', verify(later)
    assert_equal ['observed_failure', due, first.event_id], [operation.state, operation.due_at, failure['event_id']]
  end

  def test_paid_arriving_before_failure_keeps_signed_fact_but_does_not_grant_grace
    @subscription['latest_invoice']['status'] = 'paid'
    @subscription['latest_invoice']['amount_remaining'] = 0
    paid = accept(event(type: 'invoice.paid', attempt: 1))
    assert_nil operation.first_failed_at
    assert_equal 'invoice_already_resolved', verify(paid)
    failed = accept
    assert_equal 'invoice_already_resolved', verify(failed)
    assert_equal 'resolved_observation', operation.state
    assert_nil failure
    assert_equal 2, Toybaco::RenewalInvoiceFact.where(subscription_id: @sub).count
  end

  def test_foreign_customer_or_mode_never_write_failure_or_bind_operation
    row = accept
    @subscription['customer'] = 'cus_foreign'
    assert_raises(Growth::PaymentSignature::Invalid) { verify(row) }
    @subscription['customer'] = @customer
    @subscription['livemode'] = true
    assert_raises(Growth::PaymentSignature::Invalid) { verify(row) }
    assert_nil failure
    assert_nil operation.account_id
  end

  def test_scheduled_new_price_is_not_accepted_as_ordinary_renewal
    row = accept
    @subscription['items']['data'].first['price']['id'] = 'price_scheduled'
    assert_raises(Growth::PaymentSignature::Invalid) { verify(row) }
    assert_nil failure
    assert_equal 'unverified', operation.state
  end

  def test_other_invoice_is_attention_and_never_replaces_existing_failure
    row = accept
    @subscription['latest_invoice']['id'] = 'in_other'
    assert_equal 'invoice_already_resolved', verify(row)
    assert_equal 'attention', operation.state
    assert_nil failure
  end

  def test_same_invoice_with_conflicting_customer_rejects_whole_new_event
    row = accept
    conflict = event
    conflict['data']['object']['customer'] = 'cus_foreign'
    assert_raises(Growth::BillingReceipt::Conflict) { accept(conflict) }
    assert_equal 1, Toybaco::SubscriptionSyncRequest.find(row.subscription_sync_request_id).requested_revision
    refute Toybaco::BillingEvent.exists?(event_id: conflict['id'])
  end

  def test_test_and_live_events_and_due_operations_are_isolated
    value = event
    test = accept(value)
    ENV['TOYBACO_STRIPE_MODE'] = 'live'
    live = accept(value.merge('livemode' => true))
    refute_equal test.id, live.id
    assert_equal %w[live test], Toybaco::RenewalOperation.where(subscription_id: @sub).order(:mode).pluck(:mode)
    assert_equal 2, Toybaco::SubscriptionSyncRequest.where(subscription_id: @sub).count
  end

  def test_outer_transaction_rejected_before_fact_revision_or_verification
    row = accept
    Account.transaction do
      assert_raises(Growth::BillingReceipt::Conflict) { accept }
      assert_raises(Growth::RenewalFailureReceipt::Unresolved) { verify(row) }
    end
    assert_equal 1, Toybaco::RenewalInvoiceFact.where(subscription_id: @sub).count
    assert_nil failure
  end

  def test_account_deletion_keeps_minimal_fact_operation_and_marker
    row = accept
    verify(row)
    id = @account.id
    @account.destroy!
    assert_equal id, operation.account_id
    assert_equal row.id, Toybaco::RenewalInvoiceFact.find_by!(billing_event_id: row.id).billing_event_id
    assert_equal 1, Account.connection.select_value("SELECT count(*) FROM toybaco_durable_capability_acceptances WHERE capability='renewal-ingress-v1'").to_i
    assert_raises(Growth::RenewalFailureReceipt::Unresolved) { verify(row) }
  end

  def test_same_event_in_independent_database_sessions_has_one_fact_operation_and_revision
    value = event
    ids, errors = Queue.new, Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection { ids << accept(value).id }
      rescue StandardError => e
        errors << e
      end
    end
    threads.each(&:join)
    raise errors.pop unless errors.empty?

    assert_equal 1, 2.times.map { ids.pop }.uniq.size
    assert_equal [1, 1], [Toybaco::RenewalInvoiceFact.where(subscription_id: @sub).count, Toybaco::RenewalOperation.where(subscription_id: @sub).count]
    assert_equal 1, Toybaco::SubscriptionSyncRequest.find_by!(subscription_id: @sub).requested_revision
  end

  def test_due_timestamp_and_flag_off_do_not_start_settlement_or_free
    row = accept
    ENV['TOYBACO_BILLING_INGRESS_ENABLED'] = 'false'
    travel_to NOW + 8.days
    Growth::RenewalSettlement.stub(:new, ->(*) { raise 'N2 must remain disconnected' }) do
      assert_equal 'first_failure_recorded', verify(row)
    end
    assert_equal 'observed_failure', operation.state
    assert_nil @account.reload.internal_attributes[Growth::RenewalTransition::KEY]
  end

  def test_database_rejects_missing_deadline_or_cross_operation_first_fact
    row = accept
    assert_raises(ActiveRecord::StatementInvalid) { operation.update!(due_at: nil) }
    assert_equal row.id, Toybaco::RenewalInvoiceFact.find(operation.first_fact_id).billing_event_id
    assert_equal operation.first_failed_at + 7.days, operation.due_at
    second = event
    second['data']['object']['id'] = 'in_different'
    other = accept(second)
    foreign = Toybaco::RenewalInvoiceFact.find_by!(billing_event_id: other.id)
    assert_raises(ActiveRecord::InvalidForeignKey) { operation.update!(first_fact_id: foreign.id) }
    assert_equal row.id, Toybaco::RenewalInvoiceFact.find(operation.first_fact_id).billing_event_id
  end

  def test_worker_crash_after_verified_failure_recovers_the_same_fact_revision_and_due_time
    row = accept
    due = operation.due_at
    Growth::BillingSubscription.stub(:accept!, ->(*) { raise IOError, 'fixture after observation' }) do
      Growth::BillingExecution.new(row, client: @client).call
    end
    assert_equal ['pending', 'observed_failure'], [row.reload.state, operation.state]
    assert_equal due.to_i, failure.fetch('grace_ends_at')
    travel_to NOW + 31
    Growth::BillingExecution.new(row, client: @client).call
    assert_equal ['completed', 'subscription_accepted'], row.reload.values_at(:state, :result)
    assert_equal [1, due, 1], [row.requested_revision, operation.due_at, Toybaco::RenewalInvoiceFact.where(subscription_id: @sub).count]
    assert_equal 1, Toybaco::SubscriptionSyncRequest.find(row.subscription_sync_request_id).requested_revision
  end

  def test_worker_mode_mismatch_keeps_evidence_but_does_not_establish_failure
    row = accept
    ENV['TOYBACO_STRIPE_MODE'] = 'live'
    @client.stub(:retrieve_subscription, ->(*) { raise 'must not access provider' }) do
      Growth::BillingExecution.new(row, client: @client).call
    end
    assert_equal ['attention', 'payment_mismatch'], row.reload.values_at(:state, :result)
    assert_equal 'unverified', operation.state
    assert_nil failure
  end

  def test_corrupt_but_internally_seven_day_operation_cannot_change_signed_fact_origin
    row = accept
    record = operation
    record.update!(first_failed_at: record.first_failed_at + 60, due_at: record.due_at + 60)
    assert_raises(Growth::RenewalFailureReceipt::Unresolved) { verify(row) }
    assert_nil failure
    assert_equal 'unverified', record.reload.state
  end

  def test_stripe_read_is_outside_transaction_and_later_contract_change_is_rechecked
    row = accept
    owner = self
    @client.define_singleton_method(:retrieve_subscription) do |_|
      raise 'provider read inside transaction' if Account.connection.transaction_open?

      account = owner.instance_variable_get(:@account)
      attrs = account.internal_attributes.deep_dup
      attrs.fetch('toybaco_contract')['stripe_price_id'] = 'price_changed_during_read'
      account.update!(internal_attributes: attrs)
      owner.instance_variable_get(:@subscription).deep_dup
    end
    assert_raises(Growth::PaymentSignature::Invalid) { verify(row) }
    assert_nil failure
    assert_equal 'unverified', operation.state
  end

  def test_legacy_truncated_invoice_receipt_is_not_rewritten_or_guessed
    value = event
    attrs = Growth::BillingSnapshot.new(value).read
    short = attrs.deep_dup
    short[:snapshot]['data']['object'] = { 'subscription' => @sub }
    old = Growth::BillingReceipt.accept!(short)
    assert_raises(Growth::BillingReceipt::Conflict) { accept(value) }
    assert_equal({ 'subscription' => @sub }, old.reload.snapshot.dig('data', 'object'))
    refute Toybaco::RenewalInvoiceFact.exists?(billing_event_id: old.id)
  end
end
