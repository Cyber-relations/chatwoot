# frozen_string_literal: true

require 'rails/test_help'
require 'minitest/mock'
require 'factory_bot_rails'
require Rails.root.join('lib/toybaco/growth/purchase_session')
require Rails.root.join('lib/toybaco/growth/billing_execution')
require_relative 'toybaco_growth_purchase_stripe_fixture'

FactoryBot.find_definitions unless FactoryBot.factories.registered?(:account)

class ToybacoBillingIngressHttpTest < ActionDispatch::IntegrationTest
  include FactoryBot::Syntax::Methods
  self.use_transactional_tests = false
  VERSION = '2026-09-25.1'
  SECRET = 'whsec_fixture12345678901234567890'
  NOW = Time.utc(2026, 9, 24, 8)
  SETTINGS = { 'TOYBACO_OPENING_INGRESS_ENABLED' => 'false', 'TOYBACO_BILLING_INGRESS_ENABLED' => 'true', 'TOYBACO_STRIPE_MODE' => 'test',
               'TOYBACO_DEPLOYMENT_ENVIRONMENT' => 'staging', 'TOYBACO_STRIPE_BILLING_WEBHOOK_SECRET' => SECRET }.freeze
  Growth = Toybaco::Growth

  def setup
    @environment = ENV.to_h.slice(*SETTINGS.keys)
    ENV.update(SETTINGS)
    @adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    travel_to NOW
    data = JSON.parse(File.read(Toybaco::PlanCatalog::PATH))
    data['plans']['standard']['versions'][VERSION]['sellable'] = true
    data['current_versions']['standard'] = VERSION
    @catalog = Toybaco::PlanCatalog.new(data)
    @client = ToybacoGrowthPurchaseStripeFixture.new(@catalog)
    @account = create(:account)
    @owner = create(:user, :administrator, account: @account)
    @account.update!(internal_attributes: { Toybaco::BillingAccess::OWNER_KEY => @owner.id })
    Toybaco::Entitlements.apply!(@account, Toybaco::Entitlements.snapshot_for(@catalog.definition('free', VERSION), cycle: nil))
    selection = { 'plan_id' => 'standard', 'plan_version' => VERSION, 'cycle' => 'month' }
    Toybaco::PlanCatalog.stub(:default, @catalog) do
      Growth::PurchaseSession.new(@account, @owner, client: @client).start!(selection)
    end
    @session_id = @client.sessions.keys.fetch(0)
    @client.pay!(@session_id)
    session = @client.retrieve_checkout_session(@session_id).merge('object' => 'checkout.session')
    @event = { 'id' => "evt_#{SecureRandom.hex(10)}", 'object' => 'event', 'type' => 'checkout.session.completed',
               'livemode' => false, 'created' => NOW.to_i, 'data' => { 'object' => session } }
  end

  def teardown
    cleanup_renewal_invoice if @renewal_subscription
    Toybaco::BillingEvent.where(event_id: @event['id']).delete_all if @event
    @account&.destroy!
    @owner&.destroy!
    SETTINGS.each_key { |key| @environment.key?(key) ? ENV[key] = @environment[key] : ENV.delete(key) }
    ActiveJob::Base.queue_adapter = @adapter
    Current.reset
    travel_back
  end

  def deliver(value = @event, signature: nil)
    raw = JSON.generate(value)
    signature ||= "t=#{NOW.to_i},v1=#{OpenSSL::HMAC.hexdigest('SHA256', SECRET, "#{NOW.to_i}.#{raw}")}"
    post '/toybaco/webhooks/stripe/billing', params: raw,
         headers: { 'CONTENT_TYPE' => 'application/json', 'Stripe-Signature' => signature }
  end

  def receipt
    Toybaco::BillingEvent.find_by!(event_id: @event.fetch('id'), mode: 'test')
  end

  def test_signature_receipt_worker_and_real_purchase_fulfillment_preserve_one_store_and_contract
    deliver
    assert_response :ok
    ack = response.parsed_body
    assert_equal ['accepted', @event['id'], 'test', receipt.id], ack.values_at('status', 'event_id', 'mode', 'receipt_id')
    assert_equal 'free', Toybaco::Entitlements.contract_for(@account.reload)['plan_id']
    assert_nil @account.internal_attributes['toybaco_subscription_id']
    Growth::BillingExecution.new(receipt, client: @client).call
    assert_equal 'checkout_complete', receipt.result
    contract = Toybaco::Entitlements.contract_for(@account.reload)
    assert_equal ['standard', VERSION, 'month'], contract.values_at('plan_id', 'plan_version', 'cycle')
    sub = @account.internal_attributes['toybaco_subscription_id']
    deliver
    assert_response :ok
    Growth::BillingExecution.new(receipt, client: @client).call
    assert_equal sub, @account.reload.internal_attributes['toybaco_subscription_id']
    assert_equal 1, receipt.attempts
  end

  def test_queue_failure_after_db_commit_returns_recoverable_ack_without_applying_rights
    Toybaco::BillingEventJob.stub(:perform_later, ->(*) { raise ActiveJob::EnqueueError }) { deliver }
    assert_response :ok
    assert_equal 'pending', receipt.state
    assert_equal 'free', Toybaco::Entitlements.contract_for(@account.reload)['plan_id']
    travel_to NOW + 61
    ENV['TOYBACO_BILLING_INGRESS_ENABLED'] = 'false'
    Growth::BillingReceipt.sweep
    Growth::BillingExecution.new(receipt, client: @client).call
    assert_equal 'completed', receipt.state
  end

  def test_db_insert_failure_never_acknowledges_and_same_signed_event_is_retryable
    Toybaco::BillingEvent.stub(:create_or_find_by!, ->(*) { raise ActiveRecord::ConnectionNotEstablished }) { deliver }
    assert_response :service_unavailable
    refute Toybaco::BillingEvent.exists?(event_id: @event['id'])
    deliver
    assert_response :ok
    assert_equal 'queued', receipt.state
  end

  def test_disabled_missing_secret_wrong_signature_and_wrong_mode_do_not_accept
    ENV['TOYBACO_BILLING_INGRESS_ENABLED'] = 'false'
    deliver
    assert_response :service_unavailable
    ENV['TOYBACO_BILLING_INGRESS_ENABLED'] = 'true'
    ENV.delete('TOYBACO_STRIPE_BILLING_WEBHOOK_SECRET')
    deliver
    assert_response :service_unavailable
    ENV['TOYBACO_STRIPE_BILLING_WEBHOOK_SECRET'] = SECRET
    deliver(signature: "t=#{NOW.to_i},v1=#{'0' * 64}")
    assert_response :bad_request
    deliver(@event.merge('livemode' => true))
    assert_response :bad_request
    refute Toybaco::BillingEvent.exists?(event_id: @event['id'])
  end

  def test_old_checkout_does_not_overwrite_a_different_current_purchase
    saved = @account.reload.internal_attributes.fetch(Growth::PurchaseIntent::KEY).deep_dup
    saved['nonce'] = SecureRandom.hex(24)
    @account.update!(internal_attributes: @account.internal_attributes.merge(Growth::PurchaseIntent::KEY => saved))
    deliver
    assert_response :ok
    Growth::BillingExecution.new(receipt, client: @client).call
    assert_equal 'attention', receipt.state
    assert_equal 'free', Toybaco::Entitlements.contract_for(@account.reload)['plan_id']
    assert_nil @account.internal_attributes['toybaco_subscription_id']
  end

  def test_opening_requires_its_own_flag_and_persists_only_minimal_signed_identity
    @event['data']['object']['metadata'].delete('toybaco_existing_account_id')
    @event['data']['object']['metadata'].delete('toybaco_purchase_nonce')
    deliver
    assert_response :service_unavailable
    refute Toybaco::BillingEvent.exists?(event_id: @event['id'])
    ENV['TOYBACO_OPENING_INGRESS_ENABLED'] = 'true'
    ENV['TOYBACO_BILLING_INGRESS_ENABLED'] = 'false'
    Toybaco::BillingEventJob.stub(:perform_later, ->(*) { raise ActiveJob::EnqueueError }) { deliver }
    assert_response :ok
    assert_equal ['opening_checkout', 'pending', nil], receipt.values_at('action', 'state', 'opening_request_id')
    assert_equal({ 'id' => @session_id, 'object' => 'checkout.session' }, receipt.snapshot.dig('data', 'object'))
    deliver
    assert_response :ok
    assert_equal 1, Toybaco::BillingEvent.where(event_id: @event['id']).count
  end

  def test_opening_database_failure_never_acknowledges_and_opening_flag_does_not_admit_existing_purchase
    ENV['TOYBACO_OPENING_INGRESS_ENABLED'] = 'true'
    ENV['TOYBACO_BILLING_INGRESS_ENABLED'] = 'false'
    deliver
    assert_response :service_unavailable
    @event['data']['object']['metadata'].delete('toybaco_existing_account_id')
    @event['data']['object']['metadata'].delete('toybaco_purchase_nonce')
    Toybaco::BillingEvent.stub(:create_or_find_by!, ->(*) { raise ActiveRecord::ConnectionNotEstablished }) { deliver }
    assert_response :service_unavailable
    refute Toybaco::BillingEvent.exists?(event_id: @event['id'])
  end
  def renewal_invoice_event
    @renewal_subscription = "sub_#{SecureRandom.hex(10)}"
    @event = { 'id' => "evt_#{SecureRandom.hex(10)}", 'object' => 'event', 'type' => 'invoice.payment_failed',
      'created' => NOW.to_i - 60, 'livemode' => false, 'data' => { 'object' => {
        'object' => 'invoice', 'id' => "in_#{SecureRandom.hex(10)}", 'subscription' => @renewal_subscription,
        'customer' => "cus_#{SecureRandom.hex(10)}", 'billing_reason' => 'subscription_cycle', 'attempt_count' => 1,
        'customer_email' => 'never-retain@example.invalid' } } }
  end

  def cleanup_renewal_invoice
    rows = Toybaco::RenewalOperation.where(subscription_id: @renewal_subscription)
    rows.update_all(state: 'unverified', first_fact_id: nil, first_failed_at: nil, due_at: nil)
    Toybaco::RenewalInvoiceFact.where(subscription_id: @renewal_subscription).delete_all
    rows.delete_all
    Toybaco::BillingEvent.where(reference_id: @renewal_subscription).delete_all
    Toybaco::SubscriptionSyncRequest.where(subscription_id: @renewal_subscription).delete_all
  end

  def test_signed_renewal_http_ack_has_committed_fact_operation_and_revision
    renewal_invoice_event
    deliver
    assert_response :success
    saved = receipt
    fact = Toybaco::RenewalInvoiceFact.find_by!(billing_event_id: saved.id)
    operation = Toybaco::RenewalOperation.find(fact.renewal_operation_id)
    assert_equal [1, 'unverified', NOW - 60 + 7.days], [saved.requested_revision, operation.state, operation.due_at]
    refute_includes [saved.snapshot, fact.attributes].to_json, 'never-retain'
    deliver
    assert_response :success
    assert_equal 1, Toybaco::RenewalInvoiceFact.where(billing_event_id: saved.id).count
    assert_equal 1, Toybaco::SubscriptionSyncRequest.find(saved.subscription_sync_request_id).requested_revision
  end

  def test_renewal_http_fact_write_failure_is_not_acknowledged
    renewal_invoice_event
    Toybaco::RenewalInvoiceFact.stub(:create!, ->(*) { raise ActiveRecord::StatementInvalid, 'fixture insert failure' }) do
      deliver
    end
    assert_response :service_unavailable
    refute Toybaco::BillingEvent.exists?(event_id: @event['id'])
    refute Toybaco::RenewalOperation.exists?(subscription_id: @renewal_subscription)
    refute Toybaco::SubscriptionSyncRequest.exists?(subscription_id: @renewal_subscription)
  end

  def test_renewal_http_queue_ack_loss_keeps_one_durable_fact
    renewal_invoice_event
    Toybaco::BillingEventJob.stub(:perform_later, ->(*) { raise ActiveJob::EnqueueError }) { deliver }
    assert_response :success
    assert_equal 'pending', receipt.state
    assert_equal 1, Toybaco::RenewalInvoiceFact.where(billing_event_id: receipt.id).count
    assert_equal 1, receipt.requested_revision
  end

  def test_renewal_http_bad_signature_cannot_establish_a_due_date
    renewal_invoice_event
    deliver(signature: "t=#{NOW.to_i},v1=#{'0' * 64}")
    assert_response :bad_request
    refute Toybaco::RenewalOperation.exists?(subscription_id: @renewal_subscription)
    refute Toybaco::BillingEvent.exists?(event_id: @event['id'])
  end

end
