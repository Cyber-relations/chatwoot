# frozen_string_literal: true

require 'rails/test_help'
require 'minitest/mock'
require 'factory_bot_rails'
require Rails.root.join('lib/toybaco/growth/pack_session')
require Rails.root.join('lib/toybaco/growth/payment_execution')
require Rails.root.join('lib/toybaco/growth/payment_receipt')
require Rails.root.join('lib/toybaco/growth/payment_recovery')
require_relative 'toybaco_growth_pack_stripe_fixture'

FactoryBot.find_definitions unless FactoryBot.factories.registered?(:account)

class ToybacoGrowthPaymentsRuntimeTest < ActionDispatch::IntegrationTest
  include FactoryBot::Syntax::Methods
  self.use_transactional_tests = true
  Growth = Toybaco::Growth
  NOW = Time.utc(2026, 9, 19, 4)
  SECRET = 'whsec_fixture12345678901234567890'
  ROUTE = '/toybaco/webhooks/stripe/packs'
  ENVIRONMENT = { 'TOYBACO_STRIPE_MODE' => 'test', 'TOYBACO_DEPLOYMENT_ENVIRONMENT' => 'staging',
                  'TOYBACO_STRIPE_PACK_WEBHOOK_SECRET' => SECRET }.freeze

  def setup
    @old_env = ENV.to_h.slice(*ENVIRONMENT.keys)
    ENV.update(ENVIRONMENT)
    @old_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    travel_to NOW
    @account = create(:account)
    @owner = create(:user, :administrator, account: @account)
    @account.update!(internal_attributes: { Toybaco::BillingAccess::OWNER_KEY => @owner.id, 'toybaco_stripe_customer_id' => 'cus_packstore' })
    data = JSON.parse(File.read(Toybaco::PlanCatalog::PATH))
    data['release_candidates']['2026-09-18.1']['ai_pack']['sellable'] = true
    catalog = Toybaco::PlanCatalog.new(data)
    terms = catalog.definition('standard', '2026-09-18.1')
    Toybaco::Entitlements.apply!(@account, Toybaco::Entitlements.snapshot_for(terms, cycle: 'month'))
    @client = ToybacoGrowthPackStripeFixture.new
    Toybaco::PlanCatalog.stub(:default, catalog) do
      service = Growth::PackSession.new(@account, @owner, client: @client, environment: ENVIRONMENT)
      service.start!('request_key' => SecureRandom.uuid)
    end
    order = Toybaco::GrowthPackOrder.find_by!(account_id: @account.id)
    @event_id = @client.pay!(order.session_id)
    @event = @client.events.fetch(@event_id).deep_dup
    clear_enqueued_jobs
  end

  def teardown
    ENVIRONMENT.each_key { |key| @old_env.key?(key) ? ENV[key] = @old_env[key] : ENV.delete(key) }
    travel_back
    ActiveJob::Base.queue_adapter = @old_adapter
    Current.reset
  end

  def deliver(event = @event, raw: nil, signature: nil, timestamp: Time.now.to_i)
    raw ||= JSON.generate(event)
    signature ||= "t=#{timestamp},v1=#{OpenSSL::HMAC.hexdigest('SHA256', SECRET, "#{timestamp}.#{raw}")}"
    post ROUTE, params: raw, headers: { 'CONTENT_TYPE' => 'application/json', 'Stripe-Signature' => signature }
  end

  def receipt
    Toybaco::GrowthPaymentEvent.find_by!(event_id: @event_id)
  end

  def grants
    Toybaco::GrowthAiGrant.where(account_id: @account.id, source: 'pack')
  end

  def execute(record = receipt)
    Growth::PaymentExecution.new(record, client: @client).call
  end

  def test_acknowledgement_follows_durable_receipt_and_duplicate_delivery_has_one_grant
    @event['data']['object']['customer_details'] = { 'email' => 'private@example.invalid' }
    @event['data']['object']['metadata']['private_note'] = 'do not persist this'
    2.times { deliver; assert_response :ok }
    assert_equal 'queued', receipt.state
    assert_equal 1, Toybaco::GrowthPaymentEvent.count
    assert_equal 1, enqueued_jobs.count { |job| job[:job] == Toybaco::GrowthPaymentJob }
    refute_includes receipt.snapshot.to_json, 'private@example.invalid'
    refute_includes receipt.snapshot.to_json, 'do not persist this'
    assert_empty grants
    execute
    execute
    assert_equal 'completed', receipt.state
    assert_equal 1, grants.count
    assert_equal [500, NOW, NOW + 90.days], [grants.first.units, grants.first.starts_at, grants.first.ends_at]
  end

  def test_forged_old_or_ambiguous_signatures_and_tampered_body_are_rejected
    deliver(signature: "t=#{NOW.to_i},v1=#{'0' * 64}")
    assert_response :bad_request
    deliver(timestamp: NOW.to_i - 301)
    assert_response :bad_request
    deliver(timestamp: NOW.to_i + 301)
    assert_response :bad_request
    raw = JSON.generate(@event)
    digest = OpenSSL::HMAC.hexdigest('SHA256', SECRET, "#{NOW.to_i}.#{raw}")
    deliver(raw: raw + ' ', signature: "t=#{NOW.to_i},v1=#{digest}")
    assert_response :bad_request
    deliver(signature: "t=#{NOW.to_i},t=#{NOW.to_i},v1=#{digest}")
    assert_response :bad_request
    assert_equal 0, Toybaco::GrowthPaymentEvent.count
    assert_empty enqueued_jobs
  end

  def test_rotation_header_accepts_current_v1_without_accepting_v0_only
    raw = JSON.generate(@event)
    digest = OpenSSL::HMAC.hexdigest('SHA256', SECRET, "#{NOW.to_i}.#{raw}")
    deliver(signature: "t=#{NOW.to_i},v0=#{digest}")
    assert_response :bad_request
    deliver(signature: "t=#{NOW.to_i},v1=#{'0' * 64},v1=#{digest}")
    assert_response :ok
    assert_equal 1, Toybaco::GrowthPaymentEvent.count
  end

  def test_missing_configuration_closed_and_large_or_duplicate_json_never_queues
    ENV.delete('TOYBACO_STRIPE_PACK_WEBHOOK_SECRET')
    deliver
    assert_response :service_unavailable
    ENV['TOYBACO_STRIPE_PACK_WEBHOOK_SECRET'] = SECRET
    deliver(raw: 'a' * (Growth::PaymentSignature::MAX_BYTES + 1))
    assert_response :bad_request
    deliver(raw: '{"id":"evt_one","id":"evt_two"}')
    assert_response :bad_request
    assert_equal 0, Toybaco::GrowthPaymentEvent.count
  end

  def test_wrong_mode_connect_account_and_future_event_are_rejected
    [{ 'livemode' => true }, { 'account' => 'acct_other' }, { 'created' => NOW.to_i + 1 }, { 'object' => 'thin_event' }].each do |change|
      deliver(@event.merge(change))
      assert_response :bad_request
    end
    assert_equal 0, Toybaco::GrowthPaymentEvent.count
  end

  def test_other_checkout_and_unpaid_events_do_not_create_work
    %w[subscription setup].each do |mode|
      event = @event.deep_dup
      event['data']['object']['mode'] = mode
      deliver(event)
      assert_response :ok
    end
    @event['data']['object']['payment_status'] = 'unpaid'
    deliver
    assert_response :ok
    assert_equal 0, Toybaco::GrowthPaymentEvent.count
  end

  def test_changed_snapshot_under_same_event_id_is_rejected_but_delivery_counter_is_ignored
    deliver
    assert_response :ok
    deliver(@event.merge('pending_webhooks' => 100))
    assert_response :ok
    original = receipt.payload_digest
    @event['data']['object']['customer'] = 'cus_other'
    deliver
    assert_response :bad_request
    assert_equal original, receipt.payload_digest
    assert_empty grants
  end

  def test_database_failure_returns_retryable_status_before_acknowledgement
    Growth::PaymentReceipt.stub(:accept!, ->(*) { raise ActiveRecord::StatementInvalid, 'fixture database unavailable' }) do
      deliver
    end
    assert_response :service_unavailable
    assert_empty enqueued_jobs
    assert_equal 0, Toybaco::GrowthPaymentEvent.count
  end

  def test_enqueue_failure_keeps_receipt_and_sweep_recovers_it_after_restart
    Toybaco::GrowthPaymentJob.stub(:perform_later, ->(*) { raise ActiveJob::EnqueueError, 'fixture redis unavailable' }) { deliver }
    assert_response :ok
    assert_equal 'pending', receipt.state
    travel_to NOW + 61.seconds
    Toybaco::GrowthPaymentSweepJob.perform_now
    assert_equal 'queued', receipt.state
    assert_equal 1, enqueued_jobs.count { |job| job[:job] == Toybaco::GrowthPaymentJob }
    Toybaco::Checkout::Client.stub(:new, @client) { Toybaco::GrowthPaymentJob.perform_now(receipt.id) }
    assert_equal 'completed', receipt.state
    assert_equal 1, grants.count
  end

  def test_provider_failure_retries_from_saved_receipt_without_new_checkout
    deliver
    @client.stub(:retrieve_checkout_session, ->(*) { raise Toybaco::Checkout::Error, 'fixture network error' }) { execute }
    assert_equal ['pending', 1], [receipt.state, receipt.attempts]
    assert_empty grants
    travel_to NOW + 61.seconds
    Toybaco::GrowthPaymentSweepJob.perform_now
    execute
    assert_equal ['completed', 2], [receipt.state, receipt.attempts]
    assert_equal 1, @client.sessions.length
    assert_equal 1, grants.count
  end

  def test_crash_after_grant_commit_is_recovered_without_double_fulfillment
    deliver
    execution = Growth::PaymentExecution.new(receipt, client: @client)
    execution.stub(:finish!, ->(*) { raise 'fixture worker terminated' }) do
      assert_raises(RuntimeError) { execution.call }
    end
    assert_equal 'processing', receipt.state
    assert_equal 1, grants.count
    execute
    assert_equal 'processing', receipt.state
    travel_to NOW + 301.seconds
    Toybaco::GrowthPaymentSweepJob.perform_now
    execute
    assert_equal 'completed', receipt.state
    assert_equal 1, grants.count
  end

  def test_authenticated_event_survives_provider_event_history_expiry
    deliver
    @client.events.clear
    travel_to NOW + 40.days
    execute
    assert_equal 'completed', receipt.state
    assert_equal NOW, grants.first.starts_at
    assert_equal NOW + 90.days, grants.first.ends_at
  end

  def test_refund_arriving_first_prevents_the_later_checkout_from_granting
    payment_id = @client.sessions.values.first.fetch('payment_intent')
    charge = @client.payments.fetch(payment_id).fetch('latest_charge')
    charge.merge!('refunded' => true, 'amount_refunded' => 6050)
    refund = { 'id' => 'evt_refund', 'object' => 'event', 'livemode' => false, 'created' => NOW.to_i,
               'type' => 'charge.refunded', 'data' => { 'object' => charge.deep_dup } }
    deliver(refund)
    assert_response :ok
    execute(Toybaco::GrowthPaymentEvent.find_by!(event_id: 'evt_refund'))
    deliver
    execute
    assert_equal ['completed', 'refunded'], [receipt.state, receipt.result]
    assert_empty grants
  end

  def test_mismatched_paid_store_or_exhausted_retries_remain_for_billing_attention
    deliver
    @client.sessions.values.first['customer'] = 'cus_other'
    execute
    assert_equal ['attention', 'payment_mismatch'], [receipt.state, receipt.result]
    assert_empty grants
    clear_enqueued_jobs
    Toybaco::GrowthPaymentSweepJob.perform_now
    assert_empty enqueued_jobs
    receipt.update!(state: 'queued', attempts: 19)
    @client.stub(:retrieve_checkout_session, ->(*) { raise Toybaco::Checkout::Error, 'fixture network error' }) { execute }
    assert_equal ['attention', 20], [receipt.state, receipt.attempts]
  end

  def test_reviewed_recovery_preserves_attempt_history_and_reuses_the_same_payment
    deliver
    @client.stub(:retrieve_checkout_session, ->(*) { raise Toybaco::Checkout::Error, 'fixture network error' }) do
      receipt.update!(attempts: 19)
      execute
    end
    report = { 'receipt_id' => receipt.id, 'receipt_digest' => receipt.payload_digest, 'reviewed' => true,
               'report_digest' => 'b' * 64, 'operator_reference' => 'billing-review-20260919-1' }
    2.times { assert_equal 'queued', Growth::PaymentRecovery.retry!(report) }
    assert_equal [20, 40, 1], [receipt.attempts, receipt.attempt_limit, receipt.recovery_log.length]
    assert_raises(Growth::PaymentRecovery::Invalid) { Growth::PaymentRecovery.retry!(report.merge('report_digest' => 'c' * 64)) }
    execute
    assert_equal ['completed', 21], [receipt.state, receipt.attempts]
    assert_equal 1, grants.count
    assert_equal 1, @client.sessions.length
  end

  def test_unreviewed_or_wrong_receipt_cannot_restart_payment_processing
    deliver
    receipt.update!(state: 'attention')
    report = { 'receipt_id' => receipt.id, 'receipt_digest' => receipt.payload_digest, 'reviewed' => true,
               'report_digest' => 'b' * 64, 'operator_reference' => 'billing-review-20260919-2' }
    [{ 'reviewed' => false }, { 'receipt_digest' => 'c' * 64 }, { 'receipt_id' => receipt.id.to_s }].each do |change|
      assert_raises(Growth::PaymentRecovery::Invalid) { Growth::PaymentRecovery.retry!(report.merge(change)) }
    end
    assert_equal 'attention', receipt.state
    assert_empty receipt.recovery_log
    assert_empty grants
  end
  def renewal_event(attempt: 1, created: NOW.to_i - 30, event_id: 'evt_renewalfirst')
    contract = Toybaco::Entitlements.contract_for(@account).merge('stripe_price_id' => 'price_renewal', 'subscription_item_id' => 'si_renewal')
    Toybaco::Entitlements.apply!(@account, contract, subscription_id: 'sub_renewal')
    @renewal_subscription = {
      'id' => 'sub_renewal', 'customer' => 'cus_packstore', 'livemode' => false, 'status' => 'past_due',
      'items' => { 'has_more' => false, 'data' => [{ 'id' => 'si_renewal', 'quantity' => 1,
        'current_period_start' => NOW.to_i - 60, 'current_period_end' => (NOW + 30.days).to_i,
        'price' => { 'id' => 'price_renewal' } }] },
      'latest_invoice' => { 'id' => 'in_renewal', 'status' => 'open', 'amount_remaining' => 19800,
        'currency' => 'jpy', 'billing_reason' => 'subscription_cycle', 'subscription' => 'sub_renewal' }
    }
    owner = self
    @client.define_singleton_method(:retrieve_subscription) { |_id| owner.instance_variable_get(:@renewal_subscription).deep_dup }
    @event_id = event_id
    { 'id' => event_id, 'object' => 'event', 'type' => 'invoice.payment_failed', 'created' => created, 'livemode' => false,
      'data' => { 'object' => { 'id' => 'in_renewal', 'object' => 'invoice', 'customer' => 'cus_packstore',
        'parent' => { 'subscription_details' => { 'subscription' => 'sub_renewal' } },
        'billing_reason' => 'subscription_cycle', 'attempt_count' => attempt,
        'customer_email' => 'private@example.invalid', 'metadata' => { 'unneeded' => 'do not save' } } } }
  end

  def renewal_clock
    @account.reload.internal_attributes[Growth::RenewalFailureReceipt::KEY]
  end

  def test_signed_first_failure_is_durable_minimal_and_does_not_grant_any_rights
    event = renewal_event
    contract = Toybaco::Entitlements.contract_for(@account)
    deliver(event)
    assert_response :ok
    refute_includes receipt.snapshot.to_json, 'private@example.invalid'
    refute_includes receipt.snapshot.to_json, 'do not save'
    assert_equal 'renewal_failure', receipt.action
    assert_nil renewal_clock
    execute
    assert_equal 'completed', receipt.reload.state
    assert_equal event['created'], renewal_clock['first_failed_at']
    assert_equal event['created'] + 7.days, renewal_clock['grace_ends_at']
    assert_equal contract, Toybaco::Entitlements.contract_for(@account)
    assert_empty Toybaco::GrowthAiGrant.where(account_id: @account.id)
    assert @account.active?
  end

  def test_duplicate_first_failure_uses_event_time_even_when_retried_days_later
    event = renewal_event
    deliver(event)
    execute
    original = renewal_clock.deep_dup
    travel_to NOW + 3.days
    deliver(event)
    execute
    assert_equal original, renewal_clock
    assert_equal 1, Toybaco::GrowthPaymentEvent.where(reference_id: 'in_renewal').count
  end

  def test_later_attempt_arriving_first_never_invents_the_initial_failure_time
    event = renewal_event(attempt: 3)
    deliver(event)
    execute
    assert_equal 'awaiting_first_failure', receipt.reload.result
    assert_nil renewal_clock
    @event_id = 'evt_firstarriveslate'
    event['id'] = @event_id
    event['created'] -= 10
    event['data']['object']['attempt_count'] = 1
    deliver(event)
    execute
    assert_equal event['created'], renewal_clock['first_failed_at']
  end

  def test_replacement_invoice_in_same_period_cannot_restart_seven_days
    event = renewal_event
    deliver(event)
    execute
    original = renewal_clock.deep_dup
    @event_id = 'evt_replacement'
    event['id'] = @event_id
    event['created'] += 10
    event['data']['object']['id'] = 'in_replacement'
    @renewal_subscription['latest_invoice']['id'] = 'in_replacement'
    @renewal_subscription['items']['data'].first['current_period_end'] += 1.day
    deliver(event)
    execute
    assert_equal original, renewal_clock
    assert_equal 'first_failure_already_recorded', receipt.reload.result
  end

  def test_earlier_first_failure_can_shorten_but_not_extend_the_deadline
    event = renewal_event
    deliver(event)
    execute
    @event_id = 'evt_earlierfirst'
    event['id'] = @event_id
    event['created'] -= 10
    deliver(event)
    execute
    assert_equal event['created'], renewal_clock['first_failed_at']
    assert_equal event['created'] + 7.days, renewal_clock['grace_ends_at']
  end

  def test_paid_or_replaced_invoice_does_not_create_a_new_failure_clock
    event = renewal_event
    @renewal_subscription['latest_invoice']['status'] = 'paid'
    deliver(event)
    execute
    assert_equal 'invoice_already_resolved', receipt.reload.result
    assert_nil renewal_clock
  end

  def test_wrong_live_mode_or_customer_is_attention_and_cannot_change_a_store
    event = renewal_event
    @renewal_subscription['customer'] = 'cus_other'
    deliver(event)
    execute
    assert_equal 'attention', receipt.reload.state
    assert_nil renewal_clock
    @event_id = 'evt_wrongmode'
    event['id'] = @event_id
    @renewal_subscription['customer'] = 'cus_packstore'
    @renewal_subscription['livemode'] = true
    deliver(event)
    execute
    assert_equal 'attention', receipt.reload.state
    assert_nil renewal_clock
  end

  def test_initial_and_upgrade_failures_are_not_regular_renewal_receipts
    event = renewal_event
    %w[subscription_create subscription_update manual].each do |reason|
      event['data']['object']['billing_reason'] = reason
      deliver(event)
      assert_response :ok
    end
    assert_empty Toybaco::GrowthPaymentEvent.where(action: 'renewal_failure')
    assert_nil renewal_clock
  end

  def test_invalid_attempt_or_event_identity_cannot_be_saved_as_a_failure
    event = renewal_event
    [0, -1, nil, '1'].each do |attempt|
      event['data']['object']['attempt_count'] = attempt
      deliver(event)
      assert_response :bad_request
    end
    assert_empty Toybaco::GrowthPaymentEvent.where(action: 'renewal_failure')
  end

  def advance_failed_invoice!(event)
    @event_id = 'evt_nextunpaidmonth'
    event['id'] = @event_id
    event['created'] = (NOW + 31.days).to_i
    event['data']['object']['id'] = 'in_nextunpaidmonth'
    @renewal_subscription['latest_invoice']['id'] = 'in_nextunpaidmonth'
    item = @renewal_subscription['items']['data'].first
    item['current_period_start'] = (NOW + 30.days).to_i
    item['current_period_end'] = (NOW + 60.days).to_i
    travel_to NOW + 31.days
  end

  def test_next_unpaid_month_and_changed_period_end_do_not_restart_the_clock
    event = renewal_event
    deliver(event)
    execute
    original = renewal_clock.deep_dup
    advance_failed_invoice!(event)
    deliver(event)
    execute
    assert_equal original, renewal_clock
    assert_equal 'first_failure_already_recorded', receipt.reload.result
  end

  def test_verified_paid_coverage_between_failures_permits_the_next_normal_renewal_clock
    event = renewal_event
    deliver(event)
    execute
    paid = { 'subscription_id' => 'sub_renewal', 'invoice_id' => 'in_renewal', 'paid_at' => NOW.to_i,
             'term_start' => NOW.to_i - 60, 'term_end' => (NOW + 30.days).to_i }
    @account.update!(internal_attributes: @account.reload.internal_attributes.merge(Growth::PaidPeriod::KEY => paid))
    advance_failed_invoice!(event)
    deliver(event)
    execute
    assert_equal event['created'], renewal_clock['first_failed_at']
    assert_equal event['created'] + 7.days, renewal_clock['grace_ends_at']
  end

  def test_earlier_or_foreign_paid_period_cannot_reset_an_unpaid_renewal
    event = renewal_event
    deliver(event)
    execute
    original = renewal_clock.deep_dup
    paid = { 'subscription_id' => 'sub_other', 'paid_at' => NOW.to_i,
             'term_start' => NOW.to_i - 60, 'term_end' => (NOW + 30.days).to_i }
    @account.update!(internal_attributes: @account.reload.internal_attributes.merge(Growth::PaidPeriod::KEY => paid))
    advance_failed_invoice!(event)
    deliver(event)
    execute
    assert_equal original, renewal_clock
    paid.merge!('subscription_id' => 'sub_renewal', 'paid_at' => (NOW - 60).to_i)
    @account.update!(internal_attributes: @account.reload.internal_attributes.merge(Growth::PaidPeriod::KEY => paid))
    @event_id = 'evt_precedingpayment'
    event['id'] = @event_id
    deliver(event)
    execute
    assert_equal original, renewal_clock
  end

  def test_invoice_body_is_filtered_from_real_request_instrumentation
    captured = []
    listener = ActiveSupport::Notifications.subscribe('process_action.action_controller') do |*args|
      payload = args.last
      captured << payload[:params] if payload[:controller] == 'Toybaco::GrowthPaymentWebhooksController'
    end
    event = renewal_event
    event['data']['object']['customer_address'] = { 'line1' => 'private address fixture' }
    event['data']['object']['description'] = 'private customer note'
    deliver(event)
    assert_response :ok
    assert_equal 1, captured.size
    assert_equal '[FILTERED]', captured.first.dig('data', 'object')
    refute_includes captured.to_json, 'private@example.invalid'
    refute_includes captured.to_json, 'private address fixture'
    refute_includes captured.to_json, 'private customer note'
  ensure
    ActiveSupport::Notifications.unsubscribe(listener) if listener
  end

end
