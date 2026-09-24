# frozen_string_literal: true

require 'rails/test_help'
require 'minitest/mock'
require 'factory_bot_rails'
require 'timeout'
require 'action_mailbox/test_helper'
require Rails.root.join('lib/toybaco/growth/renewal_settlement')
require Rails.root.join('lib/toybaco/growth/free_return')
require Rails.root.join('lib/toybaco/growth/purchase_fulfillment')
require Rails.root.join('lib/toybaco/growth/posting_retention')
require Rails.root.join('lib/toybaco/growth/posting_execution')
require Rails.root.join('lib/toybaco/growth/posting_preparation')
require Rails.root.join('lib/toybaco/growth/posting_preparation_export')
require Rails.root.join('lib/toybaco/growth/posting_preparation_delivery')
require Rails.root.join('lib/toybaco/growth/posting_stop')
require Rails.root.join('lib/toybaco/growth/inbox_retention')
require Rails.root.join('lib/toybaco/growth/inbox_release')
require Rails.root.join('lib/toybaco/growth/draft_work')
require Rails.root.join('lib/toybaco/growth/draft_start')
require Rails.root.join('lib/toybaco/growth/retention_selection')
require Rails.root.join('lib/toybaco/growth/purchase_intent')
require Rails.root.join('lib/toybaco/growth/pack_catalog')
require Rails.root.join('lib/toybaco/growth/pack_intent')
require Rails.root.join('lib/toybaco/checkout/plan_change')
require Rails.root.join('lib/toybaco/subscription_sync')

FactoryBot.find_definitions unless FactoryBot.factories.registered?(:account)

# Keep the bounded test-container log footprint visible as the real DB suite grows.
Minitest.after_run do
  path = Rails.root.join('log/test.log')
  puts "TOYBACO_GROWTH_RUNTIME_LOG_BYTES=#{File.size(path)}" if File.file?(path)
end

class ToybacoGrowthRenewalTransitionRuntimeTest < ActiveSupport::TestCase
  include FactoryBot::Syntax::Methods
  include ActionMailbox::TestHelper
  self.use_transactional_tests = false
  Journal = Toybaco::Growth::RenewalTransition
  Settlement = Toybaco::Growth::RenewalSettlement
  NOW = Time.utc(2026, 10, 11, 12)

  class Provider
    attr_accessor :sub, :invoice, :before_void, :before_cancel
    attr_reader :calls
    def initialize(sub, invoice)
      @sub, @invoice, @calls = sub, invoice, []
    end
    def copy(value) = Marshal.load(Marshal.dump(value))
    def retrieve_subscription(*) = copy(sub)
    def retrieve_invoice(*) = copy(invoice)
    def list_customer_subscriptions(*) = { 'data' => [copy(sub)], 'has_more' => false }
    def list_customer_invoices(*) = { 'data' => [copy(invoice)], 'has_more' => false }
    def pending_customer_invoice_items(*) = { 'data' => [], 'has_more' => false }
    def list_invoice_payments(*) = { 'data' => [], 'has_more' => false }
    def void_invoice(*)
      @calls << 'void'
      before_void&.call
      invoice['status'] = 'void'
    end
    def cancel_unpaid_subscription(*)
      @calls << 'cancel'
      before_cancel&.call
      sub['status'] = 'canceled'
    end
  end

  def setup
    @account = create(:account)
    @owner = create(:user, :administrator, account: @account)
    start_at, end_at = (NOW - 8.days).to_i, (NOW + 22.days).to_i
    terms = Toybaco::PlanCatalog.default.definition('standard', '2026-09-18.1')
    contract = Toybaco::Entitlements.snapshot_for(terms, cycle: 'month').merge('stripe_price_id' => 'price_transition', 'subscription_item_id' => 'si_transition')
    @account.update!(internal_attributes: { Toybaco::BillingAccess::OWNER_KEY => @owner.id,
      'toybaco_contract' => contract, 'toybaco_subscription_id' => 'sub_transition', 'toybaco_stripe_customer_id' => 'cus_transition',
      Settlement::FAILURE_KEY => { 'subscription_id' => 'sub_transition', 'invoice_id' => 'in_transition', 'term_start' => start_at,
        'term_end' => end_at, 'first_failed_at' => start_at, 'grace_ends_at' => start_at + 604800 } })
    @inboxes = 2.times.map { create(:inbox, account: @account) }
    @rows = { 'inboxes' => @inboxes.map { |box| { 'id' => box.id.to_s, 'name' => 'private name', 'created_at_us' => box.created_at.to_i * 1_000_000 } },
              'posting_accounts' => [], 'posts' => [] }
    @inventory = Struct.new(:rows) { def read = rows.deep_dup }.new(@rows)
    invoice = { 'id' => 'in_transition', 'customer' => 'cus_transition', 'subscription' => 'sub_transition', 'livemode' => false,
      'currency' => 'jpy', 'status' => 'open', 'amount_paid' => 0, 'amount_remaining' => 19800,
      'billing_reason' => 'subscription_cycle', 'collection_method' => 'charge_automatically', 'subtotal' => 19800,
      'starting_balance' => 0, 'amount_shipping' => 0, 'pre_payment_credit_notes_amount' => 0, 'post_payment_credit_notes_amount' => 0,
      'lines' => { 'has_more' => false, 'data' => [{ 'id' => 'il_transition', 'currency' => 'jpy', 'quantity' => 1, 'amount' => 19800,
        'type' => 'subscription', 'subscription' => 'sub_transition', 'subscription_item' => 'si_transition',
        'proration' => false, 'price' => { 'id' => 'price_transition' }, 'period' => { 'start' => start_at, 'end' => end_at } }] } }
    sub = { 'id' => 'sub_transition', 'customer' => 'cus_transition', 'livemode' => false, 'status' => 'past_due',
      'collection_method' => 'charge_automatically', 'latest_invoice' => 'in_transition',
      'items' => { 'has_more' => false, 'data' => [{ 'id' => 'si_transition', 'quantity' => 1,
        'current_period_start' => start_at, 'current_period_end' => end_at, 'price' => { 'id' => 'price_transition' } }] } }
    @provider = Provider.new(sub, invoice)
  end

  def teardown
    @notification_keys&.each { |key| Redis::Alfred.delete(key) }
    @mailbox_inbounds&.each do |inbound|
      inbound.raw_email.purge
      inbound.destroy!
    end
    Toybaco::GrowthPostingPreparationAck.where(account_id: @account.id).delete_all
    Toybaco::GrowthPostingPreparation.where(account_id: @account.id).delete_all
    Toybaco::GrowthPostingPrincipal.where(account_id: @account.id).delete_all
    Toybaco::GrowthPostingExecution.where(account_id: @account.id).delete_all
    Toybaco::GrowthPostingStop.where(account_id: @account.id).delete_all
    if @execution_request && @account.persisted?
      @account.reload.with_lock do
        attrs = @account.internal_attributes.except('postiz')
        attrs['postiz'] = @execution_prior_postiz if @execution_prior_postiz
        @account.update_columns(internal_attributes: attrs)
      end
    end
    Toybaco::GrowthPackOrder.where(account_id: @account.id).delete_all
    @account.destroy! unless @account.destroyed?
    @membership_test_users&.each { |user| user.destroy! if User.exists?(user.id) }
    @owner.destroy!
    Current.reset
  end

  def settle
    Settlement.new(@account, client: @provider, now: NOW, inventory: @inventory, environment: { 'TOYBACO_STRIPE_MODE' => 'test' }).call
  end

  def selection
    Toybaco::Growth::RetentionSelection.new(@account, @owner, target: 'free', inventory: @inventory)
  end

  def remote_receipt
    result = nil
    worker = Thread.new do
      Account.connection_pool.with_connection { result = Account.find(@account.id).internal_attributes[Journal::KEY] }
    end
    raise 'read timed out' unless worker.join(5)

    worker.value
    result
  ensure
    if worker&.alive?
      worker.kill
      worker.join
    end
  end

  def test_choice_is_committed_before_first_external_mutation_and_survives_database_rollback
    picked = { 'inboxes' => [@inboxes.last.id.to_s], 'posting_accounts' => [] }
    selection.save!(selected: picked, revision: selection.read.fetch('revision'))
    observed = nil
    @provider.before_void = lambda do
      observed = remote_receipt
      @provider.invoice['status'] = 'void'
      raise 'simulated failure after Stripe commit'
    end
    assert_raises(RuntimeError) { settle }
    stored = @account.reload.internal_attributes.fetch(Journal::KEY)
    assert_equal stored, observed
    assert_equal picked, stored.dig('retention', 'selected')
    assert_equal 'prepared', stored['state']
    refute_includes stored.to_json, 'private name'
    refute @account.internal_attributes.key?(Settlement::KEY)
    @provider.before_void = nil
    @rows['inboxes'].clear
    assert_equal 'closed', settle
    assert_equal stored['id'], @account.reload.internal_attributes.dig(Journal::KEY, 'id')
    assert_equal 'provider_closed', @account.internal_attributes.dig(Journal::KEY, 'state')
    assert Journal.pending?(@account)
    assert_equal 'standard', Toybaco::Entitlements.contract_for(@account)['plan_id']
    assert_empty Toybaco::GrowthAiGrant.where(account_id: @account.id)
  end

  def test_outer_transaction_cannot_make_preparation_uncommitted
    Account.transaction { assert_equal 'retry_required', settle }
    assert_empty @provider.calls
    refute @account.reload.internal_attributes.key?(Journal::KEY)
  end

  def test_paid_race_preserves_contract_and_releases_preparation
    original = @account.internal_attributes.fetch('toybaco_contract').deep_dup
    @provider.before_void = lambda do
      @provider.invoice.merge!('status' => 'paid', 'amount_paid' => 19800)
      raise Toybaco::Checkout::Error, 'already paid'
    end
    assert_equal 'paid', settle
    assert_equal original, @account.reload.internal_attributes.fetch('toybaco_contract')
    assert_equal 'payment_recovered', @account.internal_attributes.dig(Journal::KEY, 'state')
    refute Journal.pending?(@account)
    assert_equal ['void'], @provider.calls
    assert_equal 'paid', settle
  end

  def test_open_pack_purchase_blocks_settlement_and_preserves_existing_order
    order = Toybaco::GrowthPackOrder.create!(account_id: @account.id, owner_id: @owner.id,
      nonce: 'a' * 48, request_key: SecureRandom.uuid, state: 'prepared', payload: { 'state' => 'prepared' })
    assert_equal 'billing_operation_pending', settle
    assert_empty @provider.calls
    assert_equal 'prepared', order.reload.state
    order.update_columns(state: 'unknown_provider_result')
    assert_equal 'billing_operation_pending', settle
    assert_empty @provider.calls
    refute @account.reload.internal_attributes.key?(Journal::KEY)
  end

  def test_pending_intent_blocks_owner_reselection_and_plan_change_without_reading_provider
    revision = selection.read.fetch('revision')
    @provider.before_void = -> { raise 'simulated failure' }
    assert_raises(RuntimeError) { settle }
    assert_raises(Toybaco::Growth::RetentionSelection::Changed) do
      selection.save!(selected: { 'inboxes' => [], 'posting_accounts' => [] }, revision: revision)
    end
    unavailable = Object.new
    unavailable.define_singleton_method(:retrieve_subscription) { |*| raise 'must not read provider' }
    state = Toybaco::Checkout::PlanChange.new(account: @account, client: unavailable).state
    assert_equal 'unavailable', state['status']
    assert_equal Toybaco::Checkout::PlanChange::MESSAGES['busy'], state['message']
  end

  def test_new_pack_checkout_is_blocked_but_existing_pack_records_are_not_revoked
    assert_equal 'closed', settle
    intent = Toybaco::Growth::PackIntent.new(@account, @owner, client: Object.new)
    Toybaco::Growth::PackCatalog.stub(:available?, true) do
      assert_raises(Toybaco::Growth::PurchaseIntent::Unavailable) { intent.prepare!('request_key' => SecureRandom.uuid) }
    end
    assert_empty Toybaco::GrowthPackOrder.where(account_id: @account.id)
  end

  def test_partial_free_contract_does_not_open_repurchase_before_actual_holds_complete
    assert_equal 'closed', settle
    terms = Toybaco::PlanCatalog.default.definition('free', '2026-09-18.1')
    # Simulates another writer partially applying Free. The unfinished journal
    # remains a purchase fence even if the old subscription pointer is absent.
    Toybaco::Entitlements.apply!(@account, Toybaco::Entitlements.snapshot_for(terms, cycle: nil))
    @account.update!(internal_attributes: @account.internal_attributes.except('toybaco_subscription_id'))
    intent = Toybaco::Growth::PurchaseIntent.new(@account, @owner, client: Object.new)
    assert_raises(Toybaco::Growth::PurchaseIntent::Unavailable) { intent.prepare!({}) }
    refute @account.reload.internal_attributes.key?(Toybaco::Growth::PurchaseIntent::KEY)
    assert Journal.pending?(@account)
  end

  def test_provider_closed_receipt_is_idempotent_even_if_webhook_suspended_the_account
    assert_equal 'closed', settle
    saved = @account.reload.internal_attributes.fetch(Journal::KEY)
    @account.update!(status: 'suspended')
    @inventory.define_singleton_method(:read) { raise 'must not choose again' }
    assert_equal 'closed', settle
    assert_equal saved, @account.reload.internal_attributes.fetch(Journal::KEY)
    assert_equal %w[void cancel], @provider.calls
    assert_equal 'suspended', @account.status
  end

  def test_source_contract_or_stripe_mode_change_never_reuses_old_transition
    @provider.before_void = -> { raise 'simulated failure' }
    assert_raises(RuntimeError) { settle }
    saved = @account.reload.internal_attributes.fetch(Journal::KEY).deep_dup
    @account.update!(internal_attributes: @account.internal_attributes.merge('toybaco_subscription_id' => 'sub_other'))
    assert_raises(Journal::Changed) { Journal.new(@account, now: NOW, mode: 'test').current! }
    @account.update!(internal_attributes: @account.internal_attributes.merge('toybaco_subscription_id' => 'sub_transition'))
    assert_raises(Journal::Changed) { Journal.new(@account, now: NOW, mode: 'live').current! }
    assert_equal saved, @account.reload.internal_attributes.fetch(Journal::KEY)
  end

  def test_corrupt_preparation_fails_closed_and_cannot_be_treated_as_payment_recovery
    @account.update!(internal_attributes: @account.internal_attributes.merge(Journal::KEY => { 'state' => 'payment_recovered' }))
    assert Journal.pending?(@account)
    assert_equal 'retry_required', settle
    assert_empty @provider.calls
  end

  def prepare_recovery
    @account.with_lock { Journal.new(@account, now: NOW, mode: 'test').prepare!(inventory: @inventory) }
    @account.reload.internal_attributes.fetch(Journal::KEY).deep_dup
  end

  def paid_subscription
    sub = @provider.sub.deep_dup
    invoice = @provider.invoice.deep_dup
    invoice.merge!('status' => 'paid', 'amount_due' => 19800, 'amount_paid' => 19800, 'amount_remaining' => 0,
      'status_transitions' => { 'paid_at' => NOW.to_i })
    sub.merge!('status' => 'active', 'latest_invoice' => invoice,
      'billing_cycle_anchor' => invoice.dig('lines', 'data', 0, 'period', 'start'))
    sub['items']['data'].first['price'].merge!('currency' => 'jpy', 'unit_amount' => 19800,
      'recurring' => { 'interval' => 'month', 'interval_count' => 1 })
    sub
  end

  def synchronize_paid(sub = paid_subscription, mode: 'test')
    previous = ENV['TOYBACO_STRIPE_MODE']
    ENV['TOYBACO_STRIPE_MODE'] = mode
    client = Struct.new(:value) { def retrieve_subscription(*) = value.deep_dup }.new(sub)
    travel_to(NOW) { Toybaco::SubscriptionSync.new(client: client).call(@account, subscription_id: sub['id']) }
  ensure
    previous ? ENV['TOYBACO_STRIPE_MODE'] = previous : ENV.delete('TOYBACO_STRIPE_MODE')
  end

  def test_subscription_sync_releases_only_prepared_recovery_and_preserves_ai_usage_and_packs
    saved = prepare_recovery
    start_at = saved.dig('binding', 'failure', 'term_start')
    grant = Toybaco::Growth::AiGrants.new(@account).issue!(source: 'grace',
      source_key: "paid:sub_transition:#{start_at}:base", units: 117,
      starts_at: Time.at(start_at).utc, ends_at: NOW - 1.day)
    grant.update!(used: 9)
    pack = Toybaco::Growth::AiGrants.new(@account).issue!(source: 'pack', source_key: 'pack:recoveryfixture',
      units: 500, starts_at: NOW - 1.day, ends_at: NOW + 89.days)
    pack.update!(used: 12)
    2.times { assert_equal 'applied', synchronize_paid }
    receipt = @account.reload.internal_attributes.fetch(Journal::KEY)
    assert_equal saved['id'], receipt['id']
    assert_equal saved['retention'], receipt['retention']
    assert_equal 'payment_recovered', receipt['state']
    refute Journal.pending?(@account)
    grant.reload
    pack.reload
    assert_equal ['included', 500, 9], [grant.source, grant.units, grant.used]
    assert_equal [500, 12, nil], [pack.units, pack.used, pack.revoked_at]
    assert_equal 2, Toybaco::GrowthAiGrant.where(account_id: @account.id).count
    assert_equal 'standard', Toybaco::Entitlements.contract_for(@account)['plan_id']
    assert_empty @provider.calls
  end

  def test_signed_failure_can_be_removed_before_sync_without_stranding_preparation
    saved = prepare_recovery
    @account.update!(internal_attributes: @account.internal_attributes.except(Settlement::FAILURE_KEY))
    assert_equal 'applied', synchronize_paid
    assert_equal saved['id'], @account.reload.internal_attributes.dig(Journal::KEY, 'id')
    refute Journal.pending?(@account)
    assert_equal 'payment_recovered', remote_receipt['state']
  end

  def test_a_new_failure_or_customer_binding_cannot_release_an_old_preparation
    saved = prepare_recovery
    original = @account.internal_attributes.deep_dup
    replacements = [
      original.merge(Settlement::FAILURE_KEY => original[Settlement::FAILURE_KEY].merge('invoice_id' => 'in_other')),
      original.merge('toybaco_stripe_customer_id' => 'cus_other'),
      original.merge(Settlement::FAILURE_KEY => nil)
    ]
    replacements.each do |attrs|
      @account.update!(internal_attributes: attrs)
      assert_equal 'applied', synchronize_paid
      assert_equal saved, @account.reload.internal_attributes.fetch(Journal::KEY)
      assert Journal.pending?(@account)
    end
  end

  def test_other_invoice_customer_mode_or_partial_payment_cannot_release_preparation
    saved = prepare_recovery
    changes = [
      ->(sub) { sub['customer'] = 'cus_other' },
      ->(sub) { sub['livemode'] = true },
      ->(sub) { sub['latest_invoice']['id'] = 'in_other' },
      ->(sub) { sub['latest_invoice']['customer'] = 'cus_other' },
      ->(sub) { sub['latest_invoice']['livemode'] = true },
      ->(sub) { sub['latest_invoice']['amount_paid'] = 1 },
      ->(sub) { sub['latest_invoice']['amount_due'] = 0 },
      ->(sub) { sub['latest_invoice'].delete('amount_due') },
      ->(sub) { sub['latest_invoice']['starting_balance'] = -19800 },
      ->(sub) { sub['latest_invoice']['billing_reason'] = 'subscription_update' }
    ]
    changes.each do |change|
      sub = paid_subscription
      change.call(sub)
      assert_equal 'applied', synchronize_paid(sub)
      assert_equal saved, @account.reload.internal_attributes.fetch(Journal::KEY)
      assert Journal.pending?(@account)
    end
    synchronize_paid(mode: 'live')
    assert_equal saved, @account.reload.internal_attributes.fetch(Journal::KEY)
  end

  def test_paid_at_outside_failed_period_or_current_time_does_not_release_preparation
    saved = prepare_recovery
    original = @account.internal_attributes.deep_dup
    changes = [
      ->(sub) { sub['latest_invoice']['status_transitions']['paid_at'] = NOW.to_i + 1 },
      ->(sub) { sub['latest_invoice']['status_transitions']['paid_at'] = saved.dig('binding', 'failure', 'first_failed_at') - 1 },
      lambda do |sub|
        sub['items']['data'].first['current_period_end'] += 86400
        sub['latest_invoice']['lines']['data'].first['period']['end'] += 86400
      end
    ]
    changes.each do |change|
      @account.update!(internal_attributes: original)
      Toybaco::GrowthAiGrant.where(account_id: @account.id).delete_all
      sub = paid_subscription
      change.call(sub)
      synchronize_paid(sub)
      assert_equal saved, @account.reload.internal_attributes.fetch(Journal::KEY)
    end
  end

  def test_paid_sync_does_not_release_a_manually_suspended_store
    saved = prepare_recovery
    @account.update!(status: 'suspended')
    synchronize_paid
    assert_equal 'suspended', @account.reload.status
    assert_equal saved, @account.internal_attributes.fetch(Journal::KEY)
    assert_empty Toybaco::GrowthAiGrant.where(account_id: @account.id)
  end

  def test_payment_cannot_undo_provider_mutation_or_corrupt_receipt
    prepared = prepare_recovery
    %w[invoice_voided provider_closed].each do |state|
      saved = prepared.merge('state' => state)
      @account.update!(internal_attributes: @account.internal_attributes.merge(Journal::KEY => saved))
      synchronize_paid
      assert_equal saved, @account.reload.internal_attributes.fetch(Journal::KEY)
      assert Journal.pending?(@account)
    end
    corrupt = prepared.merge('id' => 'invalid')
    @account.update!(internal_attributes: @account.internal_attributes.merge(Journal::KEY => corrupt))
    synchronize_paid
    assert_equal corrupt, @account.reload.internal_attributes.fetch(Journal::KEY)
    assert Journal.pending?(@account)
  end

  def test_recovery_and_allowance_roll_back_together_if_the_sync_transaction_fails
    saved = prepare_recovery
    Account.transaction do
      synchronize_paid
      refute Journal.pending?(@account)
      assert_equal 'prepared', remote_receipt['state']
      raise ActiveRecord::Rollback
    end
    assert_equal saved, @account.reload.internal_attributes.fetch(Journal::KEY)
    assert_empty Toybaco::GrowthAiGrant.where(account_id: @account.id)
    synchronize_paid
    refute Journal.pending?(@account.reload)
    assert_equal 1, Toybaco::GrowthAiGrant.where(account_id: @account.id).count
  end
  def bridge_environment
    { 'TOYBACO_POSTING_RETENTION_ENABLED' => 'true', 'TOYBACO_POST_URL' => 'https://post.staging.toybaco.jp',
      'FRONTEND_URL' => 'https://app.staging.toybaco.jp', 'TOYBACO_STRIPE_MODE' => 'test',
      'TOYBACO_OIDC_CLIENT_SECRET' => 'retention-fixture-secret-with-32-characters' }
  end

  def posting_receipt(payload)
    { 'version' => 1, 'request_sha256' => Digest::SHA256.hexdigest(JSON.generate(payload)),
      'organization_id' => payload.fetch('organization_id'), 'transition_id' => payload.fetch('transition_id'),
      'policy_hash' => payload.fetch('policy_hash'), 'receipt_hash' => 'b' * 64, 'kept_posts' => 1, 'held_posts' => 2 }
  end

  def posting_bridge(transport, environment: bridge_environment)
    Toybaco::Growth::PostingRetention.new(@account, environment: environment, transport: transport, clock: -> { NOW }).call
  end

  def test_posting_bridge_requires_a_committed_provider_closed_journal_and_does_not_grant_free
    assert_equal 'closed', settle
    contract = @account.reload.internal_attributes['toybaco_contract'].deep_dup
    journal = @account.internal_attributes.fetch(Journal::KEY)
    transport = lambda do |payload|
      assert_equal 'provider_closed', remote_receipt['state']
      refute Account.connection.transaction_open?
      assert_equal journal['id'], payload['transition_id']
      assert_equal Toybaco::PostizSync.deterministic_organization_id(@account.id), payload['organization_id']
      assert_equal [], payload['keep_integration_ids']
      assert_equal 5, payload['scheduled_posts_per_account']
      posting_receipt(payload)
    end
    result = posting_bridge(transport)
    assert_equal result, @account.reload.internal_attributes[Toybaco::Growth::PostingRetention::KEY]
    assert_equal NOW.to_i, result['confirmed_at']
    assert_equal contract, @account.internal_attributes['toybaco_contract']
    assert_equal journal, @account.internal_attributes[Journal::KEY]
    assert Journal.pending?(@account)
    assert_empty Toybaco::GrowthAiGrant.where(account_id: @account.id)
  end

  def test_posting_bridge_retries_the_same_committed_policy_after_a_lost_response
    assert_equal 'closed', settle
    requests = []
    transport = lambda do |payload|
      requests << payload
      raise Toybaco::Growth::RetentionProtocol::Invalid if requests.size == 1
      posting_receipt(payload)
    end
    assert_raises(Toybaco::Growth::RetentionProtocol::Invalid) { posting_bridge(transport) }
    refute @account.reload.internal_attributes.key?(Toybaco::Growth::PostingRetention::KEY)
    first = posting_bridge(transport)
    assert_equal first, posting_bridge(transport)
    assert_equal 1, requests.uniq.size
  end

  def test_posting_bridge_rejects_unfinished_recovered_or_corrupt_journals_before_http
    assert_equal 'closed', settle
    original = @account.reload.internal_attributes.deep_dup
    %w[prepared invoice_voided payment_recovered].each do |state|
      attrs = original.deep_dup; attrs[Journal::KEY]['state'] = state
      @account.update!(internal_attributes: attrs)
      assert_raises(Journal::Changed) { posting_bridge(->(*) { flunk 'HTTP must not run' }) }
    end
    attrs = original.deep_dup; attrs[Journal::KEY]['id'] = 'corrupt'
    @account.update!(internal_attributes: attrs)
    assert_raises(Journal::Changed) { posting_bridge(->(*) { flunk 'HTTP must not run' }) }
  end

  def test_posting_bridge_rejects_other_mapping_environment_and_outer_transaction
    assert_equal 'closed', settle
    transport = ->(*) { flunk 'HTTP must not run' }
    assert_raises(Toybaco::Growth::RetentionProtocol::Invalid) { posting_bridge(transport, environment: bridge_environment.merge('TOYBACO_POSTING_RETENTION_ENABLED' => 'false')) }
    assert_raises(Toybaco::Growth::RetentionProtocol::Invalid) { posting_bridge(transport, environment: bridge_environment.merge('TOYBACO_STRIPE_MODE' => 'live')) }
    Account.transaction { assert_raises(Journal::Changed) { posting_bridge(transport) } }
    original = @account.reload.internal_attributes.deep_dup
    begin
      @account.update!(internal_attributes: original.merge('postiz' => { 'organization_id' => 'foreign' }))
      assert_raises(Journal::Changed) { posting_bridge(transport) }
    ensure
      @account.update!(internal_attributes: original)
    end
    assert_equal original, @account.reload.internal_attributes
  end

  def test_posting_bridge_never_records_an_ack_for_a_different_or_changed_contract
    assert_equal 'closed', settle
    transport = ->(payload) { posting_receipt(payload).merge('transition_id' => 'c' * 64) }
    assert_raises(Toybaco::Growth::RetentionProtocol::Invalid) { posting_bridge(transport) }
    refute @account.reload.internal_attributes.key?(Toybaco::Growth::PostingRetention::KEY)
    transport = lambda do |payload|
      @account.update!(internal_attributes: @account.internal_attributes.merge('toybaco_subscription_id' => 'sub_new'))
      posting_receipt(payload)
    end
    assert_raises(Journal::Changed) { posting_bridge(transport) }
    refute @account.reload.internal_attributes.key?(Toybaco::Growth::PostingRetention::KEY)
  end

  def test_posting_bridge_shares_the_billing_lock_across_database_connections
    assert_equal 'closed', settle
    transport = lambda do |payload|
      result = nil
      worker = Thread.new do
        Account.connection_pool.with_connection do
          other = Account.find(@account.id)
          result = assert_raises(Toybaco::Checkout::PlanChangeError) do
            Toybaco::Growth::PostingRetention.new(other, environment: bridge_environment,
              transport: ->(*) { flunk 'concurrent HTTP must not run' }, clock: -> { NOW }).call
          end
        end
      end
      raise 'lock check timed out' unless worker.join(5)
      worker.value
      assert_instance_of Toybaco::Checkout::PlanChangeError, result
      posting_receipt(payload)
    end
    assert_equal NOW.to_i, posting_bridge(transport)['confirmed_at']
  end

  def test_retention_protocol_matches_the_same_typescript_vector
    protocol = Toybaco::Growth::RetentionProtocol
    vector = JSON.parse(File.read(File.join(__dir__, 'fixtures/posting-retention-protocol-v1.json')))
    body = vector.fetch('body')
    config = protocol.configuration(bridge_environment)
    assert_equal body['organization_id'], Toybaco::PostizSync.deterministic_organization_id(body['account_id'])
    policy = { 'organizationId' => body['organization_id'], 'transitionId' => body['transition_id'],
      'keepIntegrationIds' => body['keep_integration_ids'].sort, 'scheduledPostsPerAccount' => body['scheduled_posts_per_account'] }
    assert_equal body['policy_hash'], Digest::SHA256.hexdigest(JSON.generate(policy))
    %w[POST RESPONSE].zip(%w[request_signature response_signature]).each do |direction, name|
      assert_equal vector[name], protocol.signature(JSON.generate(body), key: config[:key], now: Time.at(vector['stamp']), direction: direction)
    end
  end

  def test_retention_protocol_rejects_tampered_expired_reflected_and_wrong_request_responses
    protocol = Toybaco::Growth::RetentionProtocol
    request = JSON.parse(File.read(File.join(__dir__, 'fixtures/posting-retention-protocol-v1.json')))['body']
    value = posting_receipt(request); raw = JSON.generate(value); key = protocol.configuration(bridge_environment)[:key]
    sign = ->(text, now = NOW, direction = 'RESPONSE') { protocol.signature(text, key: key, now: now, direction: direction) }
    verify = ->(text, header) { protocol.response!(text, header: header, key: key, now: NOW, request: request) }
    assert_equal value, verify.call(raw, sign.call(raw))
    [[raw + ' ', sign.call(raw)], [raw, sign.call(raw, NOW - 61)], [raw, sign.call(raw, NOW, 'POST')],
     [raw, 'invalid']].each { |text, header| assert_raises(protocol::Invalid) { verify.call(text, header) } }
    [{ 'request_sha256' => 'a' * 64 }, { 'organization_id' => 'other' }, { 'policy_hash' => 'c' * 64 },
     { 'kept_posts' => -1 }, { 'held_posts' => 10001 }, { 'receipt_hash' => 'broken' }, { 'extra' => true }].each do |change|
      text = JSON.generate(value.merge(change)); assert_raises(protocol::Invalid) { verify.call(text, sign.call(text)) }
    end
  end

  def test_retention_transport_uses_fixed_tls_origin_no_proxy_no_retry_and_bounded_signed_response
    protocol = Toybaco::Growth::RetentionProtocol
    request = JSON.parse(File.read(File.join(__dir__, 'fixtures/posting-retention-protocol-v1.json')))['body']
    key = protocol.configuration(bridge_environment)[:key]
    value = posting_receipt(request); raw = JSON.generate(value)
    signature = protocol.signature(raw, key: key, now: NOW, direction: 'RESPONSE')
    response = Struct.new(:code, :content_type, :raw, :signature) do
      def [](name) = name == 'X-Toybaco-Retention-Signature' ? signature : nil
      def read_body = yield raw
    end.new('200', 'application/json', raw, signature)
    http = Struct.new(:use_ssl, :open_timeout, :read_timeout, :write_timeout, :max_retries, :handler) do
      def start = yield
      def request(input) = yield handler.call(input)
    end.new
    observed = []
    http.handler = lambda do |input|
      observed << input
      assert_equal '/api/toybaco/internal/posting-retention', input.path
      assert_equal 'application/json', input['Content-Type']
      assert_equal 'identity', input['Accept-Encoding']
      assert_equal JSON.generate(request), input.body
      assert_equal protocol.signature(input.body, key: key, now: NOW, direction: 'POST'), input['X-Toybaco-Retention-Signature']
      response
    end
    factory = lambda do |host, port, proxy|
      assert_equal ['post.staging.toybaco.jp', 443, nil], [host, port, proxy]
      http
    end
    transport = Toybaco::Growth::RetentionTransport.new(environment: bridge_environment, clock: -> { NOW })
    Net::HTTP.stub(:new, factory) do
      assert_equal value, transport.call(request)
      assert_equal [true, 5, 10, 5, 0], [http.use_ssl, http.open_timeout, http.read_timeout, http.write_timeout, http.max_retries]
      response.code = '302'
      assert_raises(protocol::Invalid) { transport.call(request) }
      response.code = '200'; response.raw = 'x' * (protocol::MAX_BYTES + 1)
      assert_raises(protocol::Invalid) { transport.call(request) }
      response.raw = raw; response.signature = 'invalid'
      assert_raises(protocol::Invalid) { transport.call(request) }
    end
    assert_equal 4, observed.size
  end

  def test_posting_bridge_corrupt_saved_confirmation_stops_before_an_external_retry
    assert_equal 'closed', settle
    result = posting_bridge(->(payload) { posting_receipt(payload) })
    original = @account.reload.internal_attributes.deep_dup
    [false, 'corrupt', result.merge('confirmed_at' => nil), result.merge('confirmed_at' => NOW.to_i + 1),
     result.merge('receipt_hash' => 'broken'), result.merge('policy_hash' => 'c' * 64)].each do |corrupt|
      @account.update!(internal_attributes: original.merge(Toybaco::Growth::PostingRetention::KEY => corrupt))
      assert_raises(Journal::Changed, Toybaco::Growth::RetentionProtocol::Invalid) do
        posting_bridge(->(*) { flunk 'corrupt confirmation must not reach HTTP' })
      end
    end
  end


  InboxHold = Toybaco::Growth::InboxRetention

  def inbox_hold(clock: -> { NOW }, environment: bridge_environment.merge('TOYBACO_INBOX_RETENTION_ENABLED' => 'true'))
    InboxHold.new(@account, environment: environment, clock: clock).call
  end

  def prepare_inbox_hold
    selection.save!(selected: { 'inboxes' => [@inboxes.first.id.to_s], 'posting_accounts' => [] }, revision: selection.read['revision'])
    assert_equal 'closed', settle
    posting_bridge(->(payload) { posting_receipt(payload) })
    assert_equal [@inboxes.first.id.to_s], @account.reload.internal_attributes.dig(Journal::KEY, 'retention', 'selected', 'inboxes')
  end

  def test_inbox_hold_is_bound_to_confirmed_posting_and_preserves_data_and_previous_selection
    selection.save!(selected: { 'inboxes' => [@inboxes.last.id.to_s], 'posting_accounts' => [] }, revision: selection.read['revision'])
    assert_raises(Journal::Changed) { inbox_hold }
    assert_equal 'closed', settle
    assert_raises(Journal::Changed) { inbox_hold }
    posting_bridge(->(payload) { posting_receipt(payload) })
    original = @account.reload.internal_attributes.deep_dup
    channels = @inboxes.map { |box| box.channel.reload.attributes }
    members = @account.account_users.pluck(:id, :user_id, :role)
    first = inbox_hold
    assert_equal [@inboxes.last.id.to_s], first['keep_inbox_ids']
    assert_equal original, @account.reload.internal_attributes.except(InboxHold::KEY, Toybaco::Growth::InboxDeliveryEpoch::KEY)
    epoch = Toybaco::Growth::InboxDeliveryEpoch.current(@account.id, @account.internal_attributes, first, now: NOW)
    assert_equal [@inboxes.first.id.to_s], epoch['entries'].pluck('inbox_id')
    assert_equal channels, @inboxes.map { |box| box.channel.reload.attributes }
    assert_equal members, @account.account_users.pluck(:id, :user_id, :role)
    assert_equal first, inbox_hold(clock: -> { NOW + 1.hour })
    assert_empty Toybaco::GrowthAiGrant.where(account_id: @account.id)
    assert Journal.pending?(@account.reload)
  end

  def test_inbox_hold_never_installs_when_flag_is_closed_or_inside_outer_transaction
    prepare_inbox_hold
    assert_raises(InboxHold::Invalid) { inbox_hold(environment: bridge_environment) }
    Account.transaction { assert_raises(InboxHold::Invalid) { inbox_hold } }
    refute @account.reload.internal_attributes.key?(InboxHold::KEY)
  end

  def test_inbox_hold_uses_current_committed_state_not_stale_associations_or_flag
    prepare_inbox_hold
    stale = Inbox.find(@inboxes.last.id)
    stale.account.internal_attributes
    inbox_hold
    assert_equal :allowed, InboxHold.with_inbox(@inboxes.first, now: NOW) { :allowed }
    assert_raises(InboxHold::Held) { InboxHold.with_inbox(stale, now: NOW) { flunk 'held operation' } }
    new_inbox = create(:inbox, account: @account)
    assert_raises(InboxHold::Held) { InboxHold.with_inbox(new_inbox, now: NOW) { flunk 'new connection is not implicitly retained' } }
    assert_raises(InboxHold::Invalid) { inbox_hold(environment: bridge_environment.merge('TOYBACO_INBOX_RETENTION_ENABLED' => 'false')) }
    assert_raises(InboxHold::Held) { InboxHold.with_inbox(stale, now: NOW) { flunk 'closed flag cannot reactivate' } }
  end

  def test_inbox_hold_rejects_missing_choice_and_corrupt_or_cross_store_receipts
    prepare_inbox_hold
    chosen = @inboxes.first
    # Remove the chosen inbox after preparation; never silently keep another.
    chosen.destroy!
    assert_raises(InboxHold::Invalid) { inbox_hold }
    refute @account.reload.internal_attributes.key?(InboxHold::KEY)
  end

  def test_inbox_runtime_rejects_corruption_before_operation
    prepare_inbox_hold
    saved = inbox_hold
    original = @account.reload.internal_attributes.deep_dup
    [nil, saved.merge('account_id' => @account.id + 1), saved.merge('keep_inbox_ids' => [@inboxes.last.id.to_s]),
     saved.merge('confirmed_at' => (NOW + 1.day).to_i), saved.merge('unknown' => 'value')].each do |bad|
      @account.update!(internal_attributes: original.merge(InboxHold::KEY => bad))
      assert_raises(InboxHold::Invalid) { InboxHold.with_inbox(@inboxes.first, now: NOW) { flunk 'invalid hold passed' } }
    end
    @account.update!(internal_attributes: original)
  end

  def with_remote_inbox_fence(transaction: false, exclusive: false)
    ready, release = Queue.new, Queue.new
    worker = Thread.new do
      Account.connection_pool.with_connection do
        operation = -> do
          InboxHold.with_fence(@account.id, exclusive: exclusive) { ready << true; release.pop }
        end
        transaction ? Account.transaction { operation.call } : operation.call
      end
    rescue Exception => e
      ready << e
      raise
    end
    result = Timeout.timeout(5) { ready.pop }
    raise result if result.is_a?(Exception)
    yield
  ensure
    release << true if release
    raise 'remote fence timeout' if worker && !worker.join(5)
    worker&.value
  end

  def test_inbox_hold_does_not_overtake_an_active_provider_operation
    prepare_inbox_hold
    with_remote_inbox_fence do
      assert_raises(InboxHold::Busy) { inbox_hold }
      refute @account.reload.internal_attributes.key?(InboxHold::KEY)
    end
    assert_equal NOW.to_i, inbox_hold['confirmed_at']
  end

  def test_inbox_processing_cannot_start_during_exclusive_hold_and_exception_releases_session
    Account.cache do
      assert_equal :initial, InboxHold.with_inbox(@inboxes.first, now: NOW) { :initial }
      with_remote_inbox_fence(exclusive: true) do
        assert_raises(InboxHold::Busy) { InboxHold.with_inbox(@inboxes.first, now: NOW) { flunk 'cached true bypassed lock' } }
      end
      assert_raises(RuntimeError) { InboxHold.with_inbox(@inboxes.first, now: NOW) { raise 'fixed fixture failure' } }
      with_remote_inbox_fence(exclusive: true) { assert true }
      assert_equal :again, InboxHold.with_inbox(@inboxes.first, now: NOW) { :again }
      with_remote_inbox_fence(exclusive: true) { assert true }
    end
  end

  def test_inbox_transaction_fence_survives_callback_return_until_outer_commit
    prepare_inbox_hold
    ready, release = Queue.new, Queue.new
    worker = Thread.new do
      Account.connection_pool.with_connection do
        Account.transaction do
          InboxHold.with_inbox(Inbox.find(@inboxes.first.id), now: NOW) { :created }
          ready << true
          release.pop
        end
      end
    end
    Timeout.timeout(5) { ready.pop }
    assert_raises(InboxHold::Busy) { inbox_hold }
    release << true
    raise 'transaction fence timeout' unless worker.join(5)
    worker.value
    assert_equal NOW.to_i, inbox_hold['confirmed_at']
  ensure
    release << true if release
    worker&.join(5)
  end

  def test_inbox_repeatable_read_cannot_use_a_snapshot_from_before_hold
    Account.transaction(isolation: :repeatable_read) do
      assert_raises(InboxHold::Invalid) { InboxHold.with_inbox(@inboxes.first, now: NOW) { flunk 'stale snapshot' } }
    end
  end

  def test_inbox_hold_blocks_ordinary_job_direct_send_and_retry_without_erasing_message
    conversation = create(:conversation, account: @account, inbox: @inboxes.last)
    message = create(:message, account: @account, inbox: @inboxes.last, conversation: conversation, message_type: :outgoing,
      status: :failed, content: 'unsent fixture', content_attributes: { 'external_error' => 'fixture', 'toybaco_gmail_send' => { 'state' => 'uncertain' } })
    before = message.reload.attributes
    prepare_inbox_hold
    inbox_hold
    travel_to NOW do
      assert_raises(Toybaco::Growth::InboxDispatch::Stale) { SendReplyJob.new.perform(message.id) }
      [Base::SendOnChannelService, Email::SendOnEmailService, Toybaco::Connections::GmailSend, Toybaco::Connections::MicrosoftSend].each do |klass|
        service = klass.name.start_with?('Toybaco') ? klass.new(message) : klass.new(message: message)
        assert_raises(InboxHold::Held) { service.perform }
      end
      controller = Api::V1::Accounts::Conversations::MessagesController.new
      controller.instance_variable_set(:@message, message)
      assert_raises(InboxHold::Held) { controller.retry }
    end
    assert_equal before, message.reload.attributes
  end

  def test_inbox_creation_guard_preserves_private_notes_and_blocks_public_messages_before_commit
    conversation = create(:conversation, account: @account, inbox: @inboxes.last)
    prepare_inbox_hold
    inbox_hold
    travel_to NOW do
      %w[incoming outgoing template].each do |kind|
        assert_raises(InboxHold::Held) do
          conversation.messages.create!(account: @account, inbox: @inboxes.last, message_type: kind, content: 'must not persist')
        end
      end
      assert_equal 0, conversation.messages.where(content: 'must not persist').count
      note = Messages::MessageBuilder.new(@owner, conversation, { content: 'retained private note', private: true }).perform
      assert note.private?
      assert_equal 'retained private note', note.reload.content
    end
  end

  def test_inbox_hold_stops_line_imap_and_mail_fetch_before_provider_or_contact_side_effects
    email_inbox = create(:channel_email, account: @account).inbox
    prepare_inbox_hold
    inbox_hold
    before = [Contact.where(account_id: @account.id).count, Conversation.where(account_id: @account.id).count, Message.where(account_id: @account.id).count]
    travel_to NOW do
      assert_raises(InboxHold::Held) { Line::IncomingMessageService.new(inbox: @inboxes.last, params: { events: [{ 'type' => 'message' }] }).perform }
      assert_raises(InboxHold::Held) { Imap::ImapMailbox.new.process(Object.new, email_inbox.channel) }
      assert_raises(InboxHold::Held) { Inboxes::FetchImapEmailsJob.new.perform(email_inbox.channel) }
      assert_raises(InboxHold::Held) { Toybaco::GmailFetchJob.new.perform(email_inbox.channel.id) }
      assert_raises(InboxHold::Held) { Toybaco::MicrosoftFetchJob.new.perform(email_inbox.channel.id) }
    end
    assert_equal before, [Contact.where(account_id: @account.id).count, Conversation.where(account_id: @account.id).count, Message.where(account_id: @account.id).count]
  end

  def test_queued_mail_checks_hold_at_delivery_not_only_when_mail_was_built
    conversation = create(:conversation, account: @account, inbox: @inboxes.last)
    mailer = ConversationReplyMailer.new
    mailer.instance_variable_set(:@conversation, conversation)
    mailer.instance_variable_set(:@_action_name, 'email_reply')
    prepare_inbox_hold
    inbox_hold
    travel_to NOW do
      assert_raises(InboxHold::Held) { mailer.run_callbacks(:deliver) { flunk 'SMTP must not start' } }
    end
  end

  def test_inbox_hold_stops_contact_creation_and_other_incoming_provider_services
    prepare_inbox_hold
    inbox_hold
    before = Contact.where(account_id: @account.id).count
    travel_to NOW do
      assert_raises(InboxHold::Held) do
        ContactInboxWithContactBuilder.new(inbox: @inboxes.last, contact_attributes: { name: 'must not create' }).perform
      end
      [Sms::IncomingMessageService, Telegram::IncomingMessageService].each do |klass|
        assert_raises(InboxHold::Held) { klass.new(inbox: @inboxes.last, params: {}).perform }
      end
      twilio = Twilio::IncomingMessageService.new(params: {})
      twilio.stub(:twilio_channel, @inboxes.last.channel) { assert_raises(InboxHold::Held) { twilio.perform } }
      whatsapp = Whatsapp::IncomingMessageBaseService.new(inbox: @inboxes.last, params: {})
      assert_raises(InboxHold::Held) { whatsapp.send(:process_messages) }
      tiktok = Tiktok::MessageService.new(channel: @inboxes.last.channel, content: {})
      assert_raises(InboxHold::Held) { tiktok.perform }
      assert_raises(InboxHold::Held) { @inboxes.last.channel.create_contact_inbox }
    end
    assert_equal before, Contact.where(account_id: @account.id).count
  end

  def test_widget_http_rejects_held_reply_before_creating_an_empty_conversation_and_keeps_read_access
    contact = ContactInboxWithContactBuilder.new(inbox: @inboxes.last, contact_attributes: { name: 'existing fixture' }).perform
    token = Widget::TokenService.new(payload: { source_id: contact.source_id, inbox_id: @inboxes.last.id }).generate_token
    prepare_inbox_hold
    inbox_hold
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! 'app.example.com'
    count = @account.conversations.count
    travel_to NOW do
      session.post '/api/v1/widget/messages', params: { website_token: @inboxes.last.channel.website_token,
        message: { content: 'not accepted', referer_url: 'https://example.com' } }, headers: { 'X-Auth-Token' => token }, as: :json
      assert_equal 409, session.response.status, session.response.body
      assert_equal InboxHold::Held.new.message, JSON.parse(session.response.body)['error']
      session.get '/api/v1/widget/messages', params: { website_token: @inboxes.last.channel.website_token }, headers: { 'X-Auth-Token' => token }
      assert_equal 200, session.response.status, session.response.body
    end
    assert_equal count, @account.conversations.count
    assert_equal 'existing fixture', contact.contact.reload.name
    assert_equal 0, @account.messages.where(content: 'not accepted').count
  end

  def test_public_api_http_rejects_contact_creation_before_side_effects
    api_inbox = create(:inbox, account: @account, channel: build(:channel_api, account: @account))
    prepare_inbox_hold
    inbox_hold
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! 'app.example.com'
    count = Contact.where(account_id: @account.id).count
    travel_to NOW do
      session.post "/public/api/v1/inboxes/#{api_inbox.channel.identifier}/contacts", params: { name: 'not accepted' }, as: :json
      assert_equal 409, session.response.status, session.response.body
      assert_equal InboxHold::Held.new.message, JSON.parse(session.response.body)['error']
    end
    assert_equal count, Contact.where(account_id: @account.id).count
  end

  def test_retained_widget_can_still_create_a_message_after_other_inboxes_are_held
    contact = ContactInboxWithContactBuilder.new(inbox: @inboxes.first, contact_attributes: { name: 'retained fixture' }).perform
    token = Widget::TokenService.new(payload: { source_id: contact.source_id, inbox_id: @inboxes.first.id }).generate_token
    prepare_inbox_hold
    inbox_hold
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! 'app.example.com'
    travel_to NOW do
      session.post '/api/v1/widget/messages', params: { website_token: @inboxes.first.channel.website_token,
        message: { content: 'accepted fixture', referer_url: 'https://example.com' } }, headers: { 'X-Auth-Token' => token }, as: :json
      assert_equal 200, session.response.status, session.response.body
    end
    assert_equal 1, @account.messages.where(content: 'accepted fixture', inbox_id: @inboxes.first.id).count
  end

  def test_noop_mailer_does_not_become_a_failed_delivery_when_smtp_is_disabled
    conversation = create(:conversation, account: @account, inbox: @inboxes.last)
    mailer = ConversationReplyMailer.new
    mailer.stub(:smtp_config_set_or_development?, false) do
      mailer.process(:reply_with_summary, conversation, 1)
    end
    assert_instance_of ActionMailer::Base::NullMail, mailer.message
    reached = false
    mailer.run_callbacks(:deliver) { reached = true }
    assert reached
  end

  MailboxFixtureFailure = Class.new(StandardError)

  def forwarded_mail(inbox)
    token = SecureRandom.hex(12)
    source = [
      "From: Retention Fixture <retention-#{token}@example.invalid>",
      "To: #{inbox.channel.email}",
      "Delivered-To: #{inbox.channel.email}",
      'Subject: retention atomic mail fixture',
      "Message-ID: <retention-#{token}@example.invalid>",
      'MIME-Version: 1.0',
      'Content-Type: text/plain; charset=UTF-8',
      '', 'retention atomic mail fixture'
    ].join("\r\n")
    inbound = create_inbound_email_from_source(source)
    (@mailbox_inbounds ||= []) << inbound
    inbound
  end

  def mailbox_business_counts
    [@account.contacts.count, ContactInbox.where(inbox_id: @account.inboxes.select(:id)).count,
     @account.conversations.count, @account.messages.count]
  end

  def assert_forwarded_mail_committed(inbound, inbox, original)
    assert inbound.reload.delivered?
    assert_equal original.map { |count| count + 1 }, mailbox_business_counts
    message = @account.messages.find_by!(source_id: inbound.message_id)
    assert_equal inbox.id, message.inbox_id
    assert_equal 'retention atomic mail fixture', message.content.strip
    assert message.conversation.persisted?
    assert_equal message.conversation.contact_id, message.sender_id
  end

  def test_forwarded_mail_finder_and_ingestion_are_one_transaction_against_remote_hold
    email_inbox = create(:channel_email, account: @account).inbox
    prepare_inbox_hold
    inbound = forwarded_mail(email_inbox)
    original = mailbox_business_counts
    ready, release = Queue.new, Queue.new
    pause_after_finder = Module.new do
      define_method(:find_conversation) do
        super()
        ready << [conversation.present?, conversation&.new_record?, conversation&.contact&.persisted?]
        release.pop
      end
    end
    worker = Thread.new do
      Account.connection_pool.with_connection do
        mailbox = SupportMailbox.new(ActionMailbox::InboundEmail.find(inbound.id))
        mailbox.singleton_class.prepend(pause_after_finder)
        mailbox.perform_processing
      end
    rescue Exception => error
      ready << error
      raise
    end
    found = Timeout.timeout(10) { ready.pop }
    raise found if found.is_a?(Exception)
    assert_equal [true, true, true], found
    # The worker has inserted its Contact, but no other session can see it yet.
    assert_equal original, mailbox_business_counts
    assert_raises(InboxHold::Busy) { inbox_hold }
    refute @account.reload.internal_attributes.key?(InboxHold::KEY)
    release << true
    raise 'mailbox transaction fixture timed out' unless worker.join(10)
    worker.value
    assert_forwarded_mail_committed(inbound, email_inbox, original)
    assert_equal NOW.to_i, inbox_hold['confirmed_at']
    assert_raises(InboxHold::Held) { InboxHold.with_inbox(email_inbox, now: NOW) { flunk 'held mail resumed' } }
  ensure
    release << true if release
    worker&.join(10)
    if worker&.alive?
      worker.kill
      worker.join
    end
  end

  def test_failed_forwarded_mail_rolls_back_finder_contact_and_can_be_reprocessed_once
    email_inbox = create(:channel_email, account: @account).inbox
    inbound = forwarded_mail(email_inbox)
    original = mailbox_business_counts
    mailbox = SupportMailbox.new(inbound)
    finder_ran = false
    mailbox.define_singleton_method(:process) do
      finder_ran = conversation.present? && conversation.contact.persisted?
      raise MailboxFixtureFailure, 'fixed mailbox fixture failure'
    end
    assert_raises(MailboxFixtureFailure) { mailbox.perform_processing }
    assert finder_ran
    assert inbound.reload.failed?
    assert_equal original, mailbox_business_counts
    with_remote_inbox_fence(exclusive: true) { assert true }
    SupportMailbox.new(inbound.reload).perform_processing
    assert_forwarded_mail_committed(inbound, email_inbox, original)
  end

  def test_failure_after_mail_message_creation_rolls_back_contact_conversation_and_message
    email_inbox = create(:channel_email, account: @account).inbox
    inbound = forwarded_mail(email_inbox)
    original = mailbox_business_counts
    mailbox = ReplyMailbox.new(inbound)
    persisted_message = nil
    fail_after_message = Module.new do
      define_method(:create_message) do
        super()
        persisted_message = @message.persisted?
        raise MailboxFixtureFailure, 'fixed post-message fixture failure'
      end
    end
    mailbox.singleton_class.prepend(fail_after_message)
    assert_raises(MailboxFixtureFailure) { mailbox.perform_processing }
    assert persisted_message
    assert inbound.reload.failed?
    assert_equal original, mailbox_business_counts
    ReplyMailbox.new(inbound.reload).perform_processing
    assert_forwarded_mail_committed(inbound, email_inbox, original)
  end

  def test_held_forwarded_mail_fails_before_contact_and_keeps_framework_retry_status
    email_inbox = create(:channel_email, account: @account).inbox
    prepare_inbox_hold
    inbox_hold
    inbound = forwarded_mail(email_inbox)
    original = mailbox_business_counts
    travel_to NOW do
      assert_raises(InboxHold::Held) { SupportMailbox.new(inbound).perform_processing }
    end
    assert inbound.reload.failed?
    assert inbound.raw_email.attached?
    assert_equal original, mailbox_business_counts
  end

  def test_retained_forwarded_mail_completes_through_real_callbacks_after_hold
    email_inbox = create(:channel_email, account: @account).inbox
    @inboxes[0] = email_inbox
    @rows['inboxes'] << { 'id' => email_inbox.id.to_s, 'name' => 'retained mail fixture',
      'created_at_us' => email_inbox.created_at.to_i * 1_000_000 }
    prepare_inbox_hold
    inbox_hold
    inbound = forwarded_mail(email_inbox)
    original = mailbox_business_counts
    travel_to(NOW) { SupportMailbox.new(inbound).perform_processing }
    assert_forwarded_mail_committed(inbound, email_inbox, original)
  end

  def manual_ai_fixture
    conversation = create(:conversation, account: @account, inbox: @inboxes.last, status: :open).reload
    create(:message, account: @account, inbox: @inboxes.last, conversation: conversation,
      message_type: :incoming, private: false, content: 'What are your opening hours?')
    Toybaco::Growth::StoreFacts.new(@account).save!({ 'name' => 'Retention fixture', 'hours' => '10:00-18:00' }, user: @owner)
    grant = Toybaco::Growth::AiGrants.new(@account).issue!(source: 'pack', source_key: 'retention-manual-fixture', units: 2,
      starts_at: NOW - 60, ends_at: NOW + 90.days)
    [conversation, grant]
  end

  def start_manual_ai(conversation)
    Toybaco::Growth::DraftStart.new(@account, conversation, @owner).create!(nonce: SecureRandom.uuid, draft: 'my retained text')
  end

  def test_held_inbox_cannot_allocate_a_new_manual_ai_request_or_pack_reservation
    conversation, grant = manual_ai_fixture
    prepare_inbox_hold
    inbox_hold
    travel_to NOW do
      Toybaco::Growth::DraftAccess.stub(:enabled?, true) do
        assert_raises(Toybaco::Growth::DraftStart::Unavailable) { start_manual_ai(conversation) }
      end
    end
    assert_empty Toybaco::GrowthDraftRequest.where(account_id: @account.id)
    assert_empty Toybaco::GrowthAiOperation.where(account_id: @account.id)
    assert_equal [2, 0, NOW + 90.days], [grant.reload.units, grant.used, grant.ends_at]
  end

  def test_queued_manual_ai_is_released_before_model_call_when_inbox_becomes_held
    conversation, grant = manual_ai_fixture
    travel_to NOW do
      Toybaco::Growth::DraftAccess.stub(:enabled?, true) do
        request = start_manual_ai(conversation)
        assert_equal 'queued', request.state
        prepare_inbox_hold
        inbox_hold
        model = Object.new
        called = false
        model.define_singleton_method(:generate) { |_| called = true; { 'content' => 'unexpected', 'needs_review' => false } }
        Toybaco::Growth::DraftWork.new(request, model: model).perform
        refute called
        assert_equal 'failed', request.reload.state
        assert_equal 'released', request.operation.reload.state
        assert_nil request.encrypted_input
        assert_empty conversation.messages.where(message_type: :outgoing)
      end
    end
    assert_equal [2, 0, NOW + 90.days], [grant.reload.units, grant.used, grant.ends_at]
  end

  def test_held_inbox_keeps_own_draft_status_and_cancel_available_without_new_generation
    conversation, grant = manual_ai_fixture
    travel_to NOW do
      Toybaco::Growth::DraftAccess.stub(:enabled?, true) do
        request = start_manual_ai(conversation)
        prepare_inbox_hold
        inbox_hold
        session = ActionDispatch::Integration::Session.new(Rails.application)
        context = { account_id: @account.id, conversation_id: conversation.display_id, request_id: request.id }
        Toybaco::Oidc::SessionReader.stub(:new, Struct.new(:user).new(@owner)) do
          session.get '/toybaco/growth/drafts', params: context
          assert_equal 200, session.response.status
          assert_equal false, session.response.parsed_body['available']
          assert_equal 'queued', session.response.parsed_body.dig('result', 'state')
          session.post '/toybaco/growth/drafts', params: context.merge(nonce: SecureRandom.uuid, draft: 'kept original'),
            headers: { 'Origin' => 'http://www.example.com' }, as: :json
          assert_equal 422, session.response.status
          assert_equal 1, Toybaco::GrowthDraftRequest.where(account_id: @account.id).count
          session.delete '/toybaco/growth/drafts', params: context, headers: { 'Origin' => 'http://www.example.com' }, as: :json
          assert_equal 200, session.response.status
          assert_equal 'cancelled', request.reload.error_code
          assert_equal 'released', request.operation.reload.state
        end
      end
    end
    assert_equal [2, 0, NOW + 90.days], [grant.reload.units, grant.used, grant.ends_at]
  end

  def test_manual_model_call_and_result_hold_shared_fence_until_completion
    conversation, grant = manual_ai_fixture
    ready, release = Queue.new, Queue.new
    worker = nil
    calls = 0
    travel_to NOW do
      Toybaco::Growth::DraftAccess.stub(:enabled?, true) do
        request = start_manual_ai(conversation)
        prepare_inbox_hold
        model = Object.new
        model.define_singleton_method(:generate) do |_prompt|
          calls += 1
          ready << true
          release.pop
          { 'content' => '10:00-18:00', 'needs_review' => false }
        end
        worker = Thread.new do
          Account.connection_pool.with_connection do
            fresh = Toybaco::GrowthDraftRequest.find(request.id)
            Toybaco::Growth::DraftWork.new(fresh, model: model).perform
            ready << fresh.reload.state
          end
        rescue Exception => error
          ready << error
          raise
        end
        started = Timeout.timeout(10) { ready.pop }
        raise started if started.is_a?(Exception)
        assert_equal true, started
        assert_raises(InboxHold::Busy) { inbox_hold }
        refute @account.reload.internal_attributes.key?(InboxHold::KEY)
        release << true
        raise 'manual model fixture timed out' unless worker.join(10)
        worker.value
        assert_equal 'completed', request.reload.state
        assert_equal 'consumed', request.operation.reload.state
        assert_equal 1, conversation.messages.where(message_type: :outgoing, private: true).count
        assert_equal NOW.to_i, inbox_hold['confirmed_at']
        Toybaco::Growth::DraftWork.new(request, model: model).perform
        assert_equal 'completed', request.reload.state
        assert_equal 1, calls
      end
    end
    assert_equal [2, 1, NOW + 90.days], [grant.reload.units, grant.used, grant.ends_at]
  ensure
    release << true if release
    worker&.join(10)
    if worker&.alive?
      worker.kill
      worker.join
    end
  end

  FreeReturn = Toybaco::Growth::FreeReturn
  FreeRecord = Toybaco::Growth::FreeReturnRecord

  def return_free(now: NOW, environment: nil)
    environment ||= bridge_environment.merge('TOYBACO_GROWTH_FREE_RETURN_ENABLED' => 'true')
    FreeReturn.new(@account, client: @provider, environment: environment, now: now, inventory: @inventory).call
  end

  def prepare_free_return
    registration = { 'phase' => 'active', 'free_anchor' => '2026-01-31T12:00:00Z' }
    @account.update!(internal_attributes: @account.internal_attributes.merge('toybaco_growth_registration' => registration))
    prepare_inbox_hold
    inbox_hold
  end

  def included_fixture(key = 'paid:sub_transition:fixture:base')
    Toybaco::Growth::AiGrants.new(@account).issue!(source: 'included', source_key: key,
      units: 500, starts_at: NOW - 1.day, ends_at: NOW + 20.days)
  end

  def test_free_completion_atomically_records_holds_contract_epoch_and_one_allowance
    prepare_free_return
    old = included_fixture
    old.update!(used: 117)
    pack = Toybaco::Growth::AiGrants.new(@account).issue!(source: 'pack', source_key: 'pack:freefixture',
      units: 500, starts_at: NOW - 1.day, ends_at: NOW + 89.days)
    pack.update!(used: 12)
    before = @account.reload.internal_attributes.deep_dup
    inboxes = @inboxes.map { |box| box.channel.reload.attributes }
    members = @account.account_users.pluck(:id, :user_id, :role)
    receipt = return_free
    assert_equal NOW.to_i, receipt['returned_at']
    assert_equal before['toybaco_growth_registration'], @account.reload.internal_attributes['toybaco_growth_registration']
    assert_equal 'free', Toybaco::Entitlements.contract_for(@account)['plan_id']
    assert_nil @account.internal_attributes['toybaco_subscription_id']
    refute @account.internal_attributes.key?(Settlement::FAILURE_KEY)
    assert_equal before[Settlement::FAILURE_KEY], receipt['billing_history'][Settlement::FAILURE_KEY]
    assert_equal before[Journal::KEY], receipt['source_journal']
    assert_equal before[InboxHold::KEY], receipt['inbox']
    assert_equal 'free_completed', @account.internal_attributes.dig(Journal::KEY, 'state')
    refute Journal.pending?(@account)
    assert_equal 1, Toybaco::GrowthFreeReturn.where(account_id: @account.id).count
    assert_equal inboxes, @inboxes.map { |box| box.channel.reload.attributes }
    assert_equal members, @account.account_users.pluck(:id, :user_id, :role)
    assert_equal [500, 117, nil], [old.reload.units, old.used, old.revoked_at]
    assert_equal [500, 12, NOW + 89.days, nil], [pack.reload.units, pack.used, pack.ends_at, pack.revoked_at]
    assert_raises(InboxHold::Held) { InboxHold.with_inbox(@inboxes.last, now: NOW) {} }
    summary = Toybaco::Growth::AiLedger.new(@account, now: NOW).summary
    assert_equal 508, summary['remaining']
    assert_equal [20, 500], summary['grants'].map { |grant| grant['limit'] }
    @provider.stub(:retrieve_subscription, ->(*) { flunk 'completed transition must not query Stripe again' }) do
      assert_equal receipt, return_free(now: NOW + 2.days)
    end
    assert_equal 1, Toybaco::GrowthAiGrant.where(account_id: @account.id).where('source_key LIKE ?', 'free:return:%').count
    assert_equal before[InboxHold::KEY], @account.reload.internal_attributes[InboxHold::KEY]
  end

  def test_free_return_period_is_based_on_fixed_return_not_original_registration_or_reads
    prepare_free_return
    receipt = return_free
    now = NOW + 1.month + 2.days
    2.times { Toybaco::Growth::FreePeriod.new(@account, now: now).refresh! }
    grants = Toybaco::GrowthAiGrant.where(account_id: @account.id, source: 'included').order(:starts_at)
    assert_equal [NOW, NOW + 1.month], grants.pluck(:starts_at)
    assert_equal [20, 20], grants.pluck(:units)
    assert_equal NOW.to_i, FreeRecord.current(@account)['returned_at']
    assert_equal receipt, return_free(now: now)
    assert_equal 20, Toybaco::Growth::AiLedger.new(@account, now: now).summary['remaining']
  end

  def test_free_return_rolls_back_receipt_contract_and_allowance_as_one_unit
    prepare_free_return
    before = @account.reload.internal_attributes.deep_dup
    grants = Toybaco::Growth::AiGrants
    issuer = Object.new
    issuer.define_singleton_method(:issue!) { |*| raise 'fixture allowance failure' }
    grants.stub(:new, issuer) { assert_raises(RuntimeError) { return_free } }
    assert_equal before, @account.reload.internal_attributes
    assert_empty Toybaco::GrowthFreeReturn.where(account_id: @account.id)
    assert_empty Toybaco::GrowthAiGrant.where(account_id: @account.id)
    assert_equal NOW.to_i, return_free['returned_at']
  end

  def test_free_return_requires_each_hold_same_transition_and_fresh_provider_closure
    assert_raises(Journal::Changed) { return_free }
    assert_equal 'closed', settle
    assert_raises(Journal::Changed) { return_free }
    posting_bridge(->(payload) { posting_receipt(payload) })
    assert_raises(InboxHold::Invalid) { return_free }
    inbox_hold
    @provider.invoice['status'] = 'paid'
    @provider.invoice['amount_paid'] = 19800
    @provider.invoice['amount_remaining'] = 0
    assert_raises(FreeRecord::Invalid) { return_free }
    assert_equal 'standard', Toybaco::Entitlements.contract_for(@account.reload)['plan_id']
    assert Journal.pending?(@account)
    assert_empty Toybaco::GrowthFreeReturn.where(account_id: @account.id)
  end

  def test_free_return_refuses_foreign_confirmation_corrupted_record_and_disabled_entry
    prepare_free_return
    assert_raises(FreeRecord::Invalid) { return_free(environment: bridge_environment) }
    attrs = @account.internal_attributes.deep_dup
    foreign = attrs[InboxHold::KEY].merge('transition_id' => 'f' * 64)
    foreign['receipt_hash'] = Toybaco::Growth::RetentionSnapshot.fingerprint(foreign.except('receipt_hash'))
    @account.update!(internal_attributes: attrs.merge(InboxHold::KEY => foreign))
    assert_raises(FreeRecord::Invalid) { return_free }
    @account.update!(internal_attributes: attrs)
    receipt = return_free
    @account.update!(internal_attributes: @account.internal_attributes.merge(FreeRecord::KEY => FreeRecord.reference(receipt).merge('receipt_hash' => 'a' * 64)))
    assert Journal.pending?(@account)
    assert_raises(FreeRecord::Invalid) { return_free }
    assert_raises(FreeRecord::Invalid) { Toybaco::Growth::AiLedger.new(@account, now: NOW).summary }
  end

  def test_free_return_preserves_admin_suspension_and_only_resumes_verified_billing_stop
    prepare_free_return
    travel_to(NOW) { @account.update!(status: 'suspended') }
    assert_raises(FreeRecord::Invalid) { return_free }
    assert_equal 'suspended', @account.reload.status
    @account.update!(internal_attributes: @account.internal_attributes.merge('toybaco_billing_suspended' => true, 'toybaco_subscription_status' => 'canceled'))
    assert_equal NOW.to_i, return_free['returned_at']
    assert_equal 'active', @account.reload.status
    assert_equal false, @account.internal_attributes['toybaco_billing_suspended']
  end

  def test_free_return_preserves_existing_manual_lease_without_adding_old_bucket_to_new_reservations
    prepare_free_return
    grant = included_fixture
    token = 'a' * 48
    operation = Toybaco::GrowthAiOperation.create!(account: @account, grant: grant, request_key: 'a' * 64,
      context_digest: 'b' * 64, token_digest: Digest::SHA256.hexdigest(token), kind: 'reply_draft', lease_expires_at: NOW + 300)
    return_free
    ledger = Toybaco::Growth::AiLedger.new(@account, now: NOW + 1)
    result = ledger.settle(operation_id: operation.id, token: token, outcome: 'consumed') { 'private-draft:fixture' }
    assert_equal 'consumed', result['result']
    assert_equal 1, grant.reload.used
    assert_equal 20, ledger.summary['remaining']
    ledger.settle(operation_id: operation.id, token: token, outcome: 'consumed') { flunk 'duplicate charged' }
    fresh = ledger.reserve(request_key: 'c' * 64, kind: 'reply_draft', context_digest: 'd' * 64)
    refute_equal grant.id, Toybaco::GrowthAiOperation.find(fresh['operation_id']).grant_id
    assert_equal 19, ledger.summary['remaining']
    assert_equal 'denied', ledger.reserve(request_key: 'e' * 64, kind: 'automatic_reply', context_digest: 'f' * 64)['result']
  end

  def test_free_return_defers_live_automatic_lease_without_extending_or_consuming_it
    prepare_free_return
    grant = included_fixture
    operation = Toybaco::GrowthAiOperation.create!(account: @account, grant: grant, request_key: 'a' * 64,
      context_digest: 'b' * 64, token_digest: 'c' * 64, kind: 'automatic_reply', lease_expires_at: NOW + 300)
    assert_raises(InboxHold::Busy) { return_free }
    assert_equal 'standard', Toybaco::Entitlements.contract_for(@account.reload)['plan_id']
    assert_equal NOW + 300, operation.reload.lease_expires_at
    assert_empty Toybaco::GrowthFreeReturn.where(account_id: @account.id)
    assert_equal (NOW + 301).to_i, return_free(now: NOW + 301)['returned_at']
    assert_equal 0, grant.reload.used
  end

  def test_free_return_cannot_run_inside_caller_transaction
    prepare_free_return
    Account.transaction { assert_raises(FreeRecord::Invalid) { return_free } }
    assert_empty Toybaco::GrowthFreeReturn.where(account_id: @account.id)
    assert_equal 'provider_closed', @account.reload.internal_attributes.dig(Journal::KEY, 'state')
  end

  def test_free_return_waits_for_existing_inbox_processing_on_another_connection
    prepare_free_return
    ready, release = Queue.new, Queue.new
    worker = Thread.new do
      Account.connection_pool.with_connection do
        InboxHold.with_inbox(Inbox.find(@inboxes.first.id), now: NOW) { ready << true; release.pop }
      end
    end
    assert_equal true, Timeout.timeout(10) { ready.pop }
    assert_raises(InboxHold::Busy) { return_free }
    assert_empty Toybaco::GrowthFreeReturn.where(account_id: @account.id)
    release << true
    raise 'reader timed out' unless worker.join(10)
    worker.value
    assert_equal NOW.to_i, return_free['returned_at']
  ensure
    release << true if release
    worker&.join(10)
    if worker&.alive?
      worker.kill
      worker.join
    end
  end

  def original_purchase
    { 'nonce' => '9' * 48, 'state' => 'complete', 'owner_id' => @owner.id,
      'selection' => { 'plan_id' => 'standard', 'plan_version' => '2026-09-18.1', 'cycle' => 'month' },
      'price_id' => 'price_transition', 'session_id' => 'cs_test_original', 'subscription_id' => 'sub_transition',
      'amount' => 19800, 'livemode' => false, 'completed_at' => (NOW - 1.month).iso8601 }
  end

  def repurchase_price
    terms = Toybaco::PlanCatalog.default.definition('standard', '2026-09-18.1')
    { 'id' => 'price_repurchase', 'active' => true, 'currency' => 'jpy', 'unit_amount' => 19800,
      'livemode' => false, 'tax_behavior' => 'exclusive', 'billing_scheme' => 'per_unit', 'transform_quantity' => nil,
      'recurring' => { 'interval' => 'month', 'interval_count' => 1, 'usage_type' => 'licensed' },
      'metadata' => { 'toybaco_plan' => 'standard', 'toybaco_plan_version' => '2026-09-18.1' },
      'product' => { 'id' => 'prod_standard', 'active' => true, 'name' => terms['product_name'], 'description' => terms['description'] } }
  end

  def new_purchase_intent
    data = JSON.parse(File.read(Toybaco::PlanCatalog::PATH))
    data['plans']['standard']['versions']['2026-09-18.1']['sellable'] = true
    data['current_versions']['standard'] = '2026-09-18.1'
    catalog = Toybaco::PlanCatalog.new(data)
    price = repurchase_price
    client = Object.new
    client.define_singleton_method(:find_price_by_lookup_key) { |_| price }
    environment = { 'TOYBACO_DEPLOYMENT_ENVIRONMENT' => 'staging', 'TOYBACO_STRIPE_MODE' => 'test' }
    intent = Toybaco::Growth::PurchaseIntent.new(@account, @owner, client: client, environment: environment, now: NOW)
    Toybaco::PlanCatalog.stub(:default, catalog) { intent.prepare!(original_purchase['selection']) }
  end

  def checkout_session(saved, id:, subscription_id:)
    { 'id' => id, 'client_reference_id' => @account.id.to_s, 'livemode' => false, 'mode' => 'subscription',
      'metadata' => Toybaco::Growth::PurchaseForm.metadata(@account.id, saved), 'status' => 'complete', 'payment_status' => 'paid',
      'subscription' => subscription_id, 'customer' => 'cus_repurchase', 'currency' => 'jpy', 'amount_subtotal' => 19800,
      'total_details' => { 'amount_discount' => 0 } }
  end

  def test_free_return_archives_completed_checkout_and_repurchase_uses_new_nonce_and_rejects_old_events
    saved = original_purchase
    @account.update!(internal_attributes: @account.internal_attributes.merge(Toybaco::Growth::PurchaseIntent::KEY => saved))
    prepare_free_return
    receipt = return_free
    assert_equal saved, receipt['purchase']
    refute @account.reload.internal_attributes.key?(Toybaco::Growth::PurchaseIntent::KEY)
    intent = new_purchase_intent
    refute_equal saved['nonce'], intent['nonce']
    assert_equal 'prepared', intent['state']
    old_session = checkout_session(saved, id: 'cs_test_original', subscription_id: 'sub_transition')
    current_session = checkout_session(intent, id: 'cs_test_repurchase', subscription_id: 'sub_repurchase')
    subscription = paid_subscription
    subscription.merge!('id' => 'sub_repurchase', 'customer' => 'cus_repurchase', 'metadata' => current_session['metadata'])
    subscription['items']['data'].first['price'] = repurchase_price
    invoice = subscription['latest_invoice']
    invoice.merge!('id' => 'in_repurchase', 'subscription' => 'sub_repurchase', 'customer' => 'cus_repurchase', 'billing_reason' => 'subscription_create')
    invoice['lines']['data'].first.merge!('subscription' => 'sub_repurchase', 'price' => { 'id' => 'price_repurchase' })
    client = Object.new
    client.define_singleton_method(:retrieve_checkout_session) { |id| id == old_session['id'] ? old_session : current_session }
    client.define_singleton_method(:retrieve_subscription) { |_| subscription }
    fulfillment = Toybaco::Growth::PurchaseFulfillment.new(client: client)
    travel_to NOW do
      assert_raises(Toybaco::Growth::PurchaseIntent::Unavailable) { fulfillment.complete!(old_session['id']) }
      assert_equal 'complete', fulfillment.complete!(current_session['id'])
      assert_equal 'complete', fulfillment.complete!(current_session['id'])
      assert_raises(Toybaco::Growth::PurchaseIntent::Unavailable) { fulfillment.complete!(old_session['id']) }
      assert_raises(Toybaco::SubscriptionSync::Unresolved) { Toybaco::SubscriptionSync.new(client: client).call(@account, subscription_id: 'sub_transition') }
    end
    assert_equal 'sub_repurchase', @account.reload.internal_attributes['toybaco_subscription_id']
    assert_equal 'standard', Toybaco::Entitlements.contract_for(@account)['plan_id']
    assert_equal receipt, FreeRecord.current(@account)
    assert_equal 500, Toybaco::Growth::AiLedger.new(@account, now: NOW).summary['remaining']
    assert_equal receipt, return_free(now: NOW + 1.hour)
    assert_equal 'standard', Toybaco::Entitlements.contract_for(@account.reload)['plan_id']
    assert_raises(InboxHold::Held) { InboxHold.with_inbox(@inboxes.last, now: NOW) {} }
  end

  InboxRelease = Toybaco::Growth::InboxRelease
  ReleaseRecord = Toybaco::Growth::InboxReleaseRecord

  def prepare_inbox_release
    prepare_free_return
    return_free
    intent = new_purchase_intent
    session = checkout_session(intent, id: 'cs_test_release', subscription_id: 'sub_repurchase')
    sub = paid_subscription
    sub.merge!('id' => 'sub_repurchase', 'customer' => 'cus_repurchase', 'metadata' => session['metadata'])
    sub['items']['data'].first['price'] = repurchase_price
    invoice = sub['latest_invoice']
    invoice.merge!('id' => 'in_repurchase', 'subscription' => 'sub_repurchase', 'customer' => 'cus_repurchase', 'billing_reason' => 'subscription_create')
    invoice['lines']['data'].first.merge!('subscription' => 'sub_repurchase', 'price' => { 'id' => 'price_repurchase' })
    @release_reads = []
    @release_provider = Struct.new(:sub, :session, :reads, :callback) do
      def retrieve_checkout_session(*) = session.deep_dup
      def retrieve_subscription(*)
        reads << Account.connection.transaction_open?
        callback&.call
        sub.deep_dup
      end
    end.new(sub, session, @release_reads, nil)
    travel_to(NOW) { assert_equal 'complete', Toybaco::Growth::PurchaseFulfillment.new(client: @release_provider).complete!(session['id']) }
    @account.reload
    @release_reads.clear
  end

  def release_service(user = @owner, environment: nil, now: NOW)
    environment ||= bridge_environment.merge('TOYBACO_INBOX_RELEASE_ENABLED' => 'true')
    InboxRelease.new(@account, user, client: @release_provider, environment: environment, now: now)
  end

  def release_inbox(ids = [@inboxes.last.id.to_s], request_id: 'a' * 64, revision: nil)
    service = release_service
    service.call(inbox_ids: ids.sort, revision: revision || service.read['revision'], request_id: request_id)
  end

  def test_explicit_inbox_release_uses_paid_new_contract_without_changing_holds_posts_grants_or_tokens
    prepare_inbox_release
    before = @account.internal_attributes.deep_dup
    tokens = @inboxes.map { |box| box.channel.reload.attributes }
    grants = Toybaco::GrowthAiGrant.where(account_id: @account.id).order(:id).map(&:attributes)
    state = release_service.read
    assert_equal [false, true], state['inboxes'].map { |box| box['held'] }
    assert_empty @release_reads
    value = release_inbox
    assert_equal [false], @release_reads, 'Stripe retrieval must be outside a database transaction'
    assert_equal before, @account.reload.internal_attributes.except(ReleaseRecord::KEY)
    assert_equal tokens, @inboxes.map { |box| box.channel.reload.attributes }
    assert_equal grants, Toybaco::GrowthAiGrant.where(account_id: @account.id).order(:id).map(&:attributes)
    assert_equal @inboxes.map { |box| box.id.to_s }.sort, value['keep_inbox_ids']
    assert_equal value, Toybaco::GrowthInboxRelease.find_by!(account_id: @account.id, request_id: 'a' * 64).receipt
    assert Toybaco::GrowthInboxRelease.find_by!(account_id: @account.id).readonly?
    assert_equal :delivered, InboxHold.with_inbox(@inboxes.last, now: NOW) { :delivered }
    assert_equal [false, false], release_service.read['inboxes'].map { |box| box['held'] }
    refute_includes value.to_json, 'private name'
    state = Toybaco::Growth::RetentionState.new(@account, now: NOW)
    refute state.inbox_held?(@inboxes.last.id.to_s)
  end

  def test_release_replay_returns_immutable_receipt_without_overwriting_later_release_or_contract
    prepare_inbox_release
    third = create(:inbox, account: @account)
    revision = release_service.read['revision']
    first = release_inbox(revision: revision)
    second = release_inbox([third.id.to_s], request_id: 'b' * 64)
    assert_equal first['request_id'], second['previous_id']
    before = @account.reload.internal_attributes.deep_dup
    reads = @release_reads.size
    assert_equal first, release_inbox(revision: revision)
    assert_equal before, @account.reload.internal_attributes
    assert_equal reads, @release_reads.size
    assert_equal 2, Toybaco::GrowthInboxRelease.where(account_id: @account.id).count
    assert_raises(ReleaseRecord::Invalid) { release_inbox([third.id.to_s], revision: revision) }
    assert_raises(ReleaseRecord::Invalid) { release_inbox([third.id.to_s], request_id: 'c' * 64, revision: revision) }
    travel_to(NOW) { @account.update!(internal_attributes: before.merge('toybaco_subscription_id' => 'sub_later')) }
    assert_equal first, release_inbox(revision: revision)
    assert_equal 'sub_later', @account.reload.internal_attributes['toybaco_subscription_id']
    assert_raises(InboxHold::Held) { InboxHold.with_inbox(third, now: NOW) {} }
  end

  def test_release_fails_closed_for_other_store_duplicate_unknown_deleted_and_over_quota_choices
    prepare_inbox_release
    foreign = create(:inbox)
    extra = 4.times.map { create(:inbox, account: @account) }
    revision = release_service.read['revision']
    invalid = [nil, {}, 1, [nil, '1'], [1, '2'], [['1']], [foreign.id.to_s], ['999999999999'], [@inboxes.last.id.to_s] * 2, [],
               [@inboxes.first.id.to_s], extra.map { |box| box.id.to_s }.sort]
    invalid.each do |ids|
      assert_raises(ReleaseRecord::Invalid) { release_service.call(inbox_ids: ids, revision: revision, request_id: 'a' * 64) }
    end
    last = extra.pop
    last.destroy!
    assert_raises(ReleaseRecord::Invalid) { release_inbox([last.id.to_s], revision: revision) }
    assert_empty @release_reads
    assert_equal 0, Toybaco::GrowthInboxRelease.where(account_id: @account.id).count
  ensure
    foreign&.account&.destroy!
  end

  def test_release_rejects_unpaid_foreign_future_or_unbound_provider_without_any_effect
    prepare_inbox_release
    original = @release_provider.sub.deep_dup
    changes = [->(sub) { sub['status'] = 'past_due' }, ->(sub) { sub['customer'] = 'cus_other' },
      ->(sub) { sub['livemode'] = true }, ->(sub) { sub['id'] = 'sub_other' },
      ->(sub) { sub['metadata']['toybaco_purchase_nonce'] = '0' * 48 },
      ->(sub) { sub['latest_invoice']['status'] = 'open' },
      ->(sub) { sub['latest_invoice']['status_transitions']['paid_at'] = NOW.to_i + 1 },
      ->(sub) { sub['pause_collection'] = {} }, ->(sub) { sub['pending_update'] = {} }]
    before = @account.reload.internal_attributes.deep_dup
    changes.each do |change|
      @release_provider.sub = original.deep_dup
      change.call(@release_provider.sub)
      assert_raises(ReleaseRecord::Invalid) { release_inbox }
      assert_equal before, @account.reload.internal_attributes
      assert_equal 0, Toybaco::GrowthInboxRelease.where(account_id: @account.id).count
    end
  end

  def test_release_revalidates_owner_contract_and_deleted_choice_after_provider_read
    prepare_inbox_release
    staff = create(:user, :administrator, account: @account)
    revision = release_service.read['revision']
    @release_provider.callback = -> do
      Account.find(@account.id).update!(internal_attributes: @account.internal_attributes.merge(Toybaco::BillingAccess::OWNER_KEY => staff.id))
    end
    assert_raises(ReleaseRecord::Invalid) { release_inbox(revision: revision) }
    assert_equal 0, Toybaco::GrowthInboxRelease.where(account_id: @account.id).count
    @account.reload.update!(internal_attributes: @account.internal_attributes.merge(Toybaco::BillingAccess::OWNER_KEY => @owner.id))
    @release_provider.callback = -> { @inboxes.last.destroy! }
    assert_raises(ReleaseRecord::Invalid) { release_inbox }
    assert_equal 0, Toybaco::GrowthInboxRelease.where(account_id: @account.id).count
  ensure
    staff&.destroy!
  end

  def test_release_rechecks_membership_on_another_connection_even_with_query_cache_enabled
    prepare_inbox_release
    revision = release_service.read['revision']
    user_id, account_id = @owner.id, @account.id
    @release_provider.callback = -> do
      worker = Thread.new do
        Account.connection_pool.with_connection do
          AccountUser.find_by!(account_id: account_id, user_id: user_id).update!(role: :agent)
        end
      end
      assert worker.join(5)
      worker.value
    end
    Account.cache do
      assert Toybaco::BillingAccess.permissions(@account, @owner)[:can_manage_billing]
      assert_raises(ReleaseRecord::Invalid) { release_inbox(revision: revision) }
    end
    assert_equal 0, Toybaco::GrowthInboxRelease.where(account_id: @account.id).count
    refute @account.reload.internal_attributes.key?(ReleaseRecord::KEY)
  end

  def test_release_and_pointer_commit_together_or_rollback_together
    prepare_inbox_release
    before = @account.internal_attributes.deep_dup
    update = @account.method(:update!)
    @account.stub(:update!, ->(*args, **kwargs) do
      if kwargs.dig(:internal_attributes, ReleaseRecord::KEY)
        assert_equal 1, Toybaco::GrowthInboxRelease.where(account_id: @account.id).count
        raise 'fixture failed pointer write'
      end
      update.call(*args, **kwargs)
    end) { assert_raises(RuntimeError) { release_inbox } }
    assert_equal 0, Toybaco::GrowthInboxRelease.where(account_id: @account.id).count
    assert_equal before, @account.reload.internal_attributes
    assert_raises(InboxHold::Held) { InboxHold.with_inbox(@inboxes.last, now: NOW) {} }
    release_inbox
    assert_equal 1, Toybaco::GrowthInboxRelease.where(account_id: @account.id).count
  end

  def test_release_respects_existing_sender_shared_lock_and_retries_after_it_finishes
    prepare_inbox_release
    acquired, finish = Queue.new, Queue.new
    worker = Thread.new do
      Account.connection_pool.with_connection do
        InboxHold.with_inbox(Inbox.find(@inboxes.first.id), now: NOW) { acquired << true; finish.pop }
      end
    end
    Timeout.timeout(5) { acquired.pop }
    assert_raises(InboxHold::Busy) { release_inbox }
    assert_equal 0, Toybaco::GrowthInboxRelease.where(account_id: @account.id).count
    finish << true
    assert worker.join(5)
    worker.value
    release_inbox
    assert_equal :allowed, InboxHold.with_inbox(@inboxes.last, now: NOW) { :allowed }
  ensure
    finish << true if finish
    worker&.join(5)
    worker&.kill if worker&.alive?
  end

  def test_runtime_release_is_not_controlled_by_rollout_flag_and_corruption_never_reopens
    prepare_inbox_release
    receipt = release_inbox
    previous = ENV.delete('TOYBACO_INBOX_RELEASE_ENABLED')
    assert_equal :allowed, InboxHold.with_inbox(@inboxes.last, now: NOW) { :allowed }
    row = Toybaco::GrowthInboxRelease.find_by!(account_id: @account.id)
    Toybaco::GrowthInboxRelease.where(id: row.id).update_all(receipt: receipt.merge('keep_inbox_ids' => []))
    assert_raises(InboxHold::Invalid) { InboxHold.with_inbox(@inboxes.last, now: NOW) { flunk 'corrupt receipt allowed delivery' } }
    assert_raises(Toybaco::Growth::RetentionPlan::Invalid) { Toybaco::Growth::RetentionState.new(@account, now: NOW) }
    Toybaco::GrowthInboxRelease.where(id: row.id).delete_all
    assert_raises(InboxHold::Invalid) { InboxHold.with_inbox(@inboxes.last, now: NOW) {} }
  ensure
    ENV['TOYBACO_INBOX_RELEASE_ENABLED'] = previous
  end

  def test_stale_release_binding_cannot_unlock_a_different_free_or_paid_contract
    prepare_inbox_release
    release_inbox
    before = @account.reload.internal_attributes.deep_dup
    travel_to(NOW) { @account.update!(internal_attributes: before.merge('toybaco_contract' => FreeRecord.free_contract)) }
    assert_raises(InboxHold::Held) { InboxHold.with_inbox(@inboxes.last, now: NOW) {} }
    assert_equal :allowed, InboxHold.with_inbox(@inboxes.first, now: NOW) { :allowed }
    travel_to(NOW) do
      @account.update!(internal_attributes: @account.reload.internal_attributes.merge('toybaco_contract' => before['toybaco_contract'],
        'toybaco_subscription_id' => 'sub_other'))
    end
    assert_raises(InboxHold::Held) { InboxHold.with_inbox(@inboxes.last, now: NOW) {} }
    # Deliberate storage corruption bypasses the model guard to test runtime rejection.
    @account.update_columns(internal_attributes: before.except(InboxHold::KEY))
    assert_raises(InboxHold::Invalid) { InboxHold.with_inbox(@inboxes.last, now: NOW) {} }
  end

  def test_release_authorization_gate_pending_billing_and_outer_transaction_fail_before_provider
    prepare_inbox_release
    staff = create(:user, :administrator, account: @account)
    revision = release_service.read['revision']
    assert_raises(ReleaseRecord::Invalid) { release_service(staff).read }
    assert_raises(ReleaseRecord::Invalid) { release_service(environment: bridge_environment).call(inbox_ids: [@inboxes.last.id.to_s], revision: revision, request_id: 'a' * 64) }
    Account.transaction do
      assert_raises(ReleaseRecord::Invalid) { release_inbox }
    end
    before = @account.reload.internal_attributes.deep_dup
    [{ 'toybaco_billing_review' => true }, { 'toybaco_billing_payment_pending' => true },
      { 'toybaco_subscription_status' => 'past_due' }, { Settlement::FAILURE_KEY => {} }].each do |change|
      @account.update!(internal_attributes: before.merge(change))
      assert_raises(ReleaseRecord::Invalid) { release_service.read }
    end
    travel_to(NOW) { @account.update!(status: :suspended, internal_attributes: before) }
    assert_raises(ReleaseRecord::Invalid) { release_service.read }
    assert_empty @release_reads
  ensure
    staff&.destroy!
  end

  def test_release_read_and_delivery_agree_after_database_jsonb_reload
    prepare_inbox_release
    result = release_inbox
    @account.reload
    row = Toybaco::GrowthInboxRelease.find_by!(account_id: @account.id)
    assert_equal result, row.receipt
    assert ReleaseRecord.valid?(row.receipt, @account.id, now: NOW)
    assert_equal [false, false], release_service.read['inboxes'].map { |box| box['held'] }
    assert_equal :allowed, InboxHold.with_inbox(@inboxes.last, now: NOW) { :allowed }
  end


  def confirmed_next_inbox_generation
    now = NOW + 40.days
    attrs = @account.reload.internal_attributes.deep_dup
    previous = FreeRecord.current(@account)
    journal = previous['source_journal'].deep_dup
    failure = journal['binding']['failure'].merge('subscription_id' => 'sub_repurchase', 'invoice_id' => 'in_second',
      'term_start' => (NOW + 30.days).to_i, 'term_end' => (NOW + 60.days).to_i,
      'first_failed_at' => (NOW + 30.days).to_i, 'grace_ends_at' => (NOW + 37.days).to_i)
    journal['binding'].merge!('source' => Toybaco::Entitlements.contract_for(@account), 'subscription_id' => 'sub_repurchase',
      'customer_id' => 'cus_repurchase', 'failure' => failure)
    journal.merge!('state' => 'provider_closed', 'prepared_at' => now.to_i, 'observed_at' => now.to_i)
    journal['id'] = Journal.identity(journal)
    @account.update!(internal_attributes: attrs.merge(Journal::KEY => journal, Settlement::FAILURE_KEY => failure))
    bridge = Toybaco::Growth::PostingRetention.new(@account, environment: bridge_environment, clock: -> { now })
    payload = bridge.send(:request_payload, Toybaco::Growth::RetentionProtocol.configuration(bridge_environment))
    # Confirmed Postiz outcome is a fixture here. Its next-generation protocol
    # is a separate integration gate and is not enabled by these inbox tests.
    posting = posting_receipt(payload).merge('confirmed_at' => now.to_i)
    @account.update!(internal_attributes: @account.internal_attributes.merge(Toybaco::Growth::PostingRetention::KEY => posting))
    [journal, now]
  end

  def test_new_inbox_stop_replaces_only_archived_previous_generation_and_old_release_cannot_restore_it
    prepare_inbox_release
    revision = release_service.read['revision']
    first = release_inbox(revision: revision)
    original_stop = @account.internal_attributes[InboxHold::KEY].deep_dup
    next_journal, now = confirmed_next_inbox_generation
    stopped = inbox_hold(clock: -> { now })
    assert_equal next_journal['id'], stopped['transition_id']
    refute_equal original_stop['transition_id'], stopped['transition_id']
    refute @account.reload.internal_attributes.key?(ReleaseRecord::KEY)
    assert_equal original_stop, FreeRecord.current(@account)['inbox']
    assert_equal first, release_inbox(revision: revision)
    assert_equal stopped, @account.reload.internal_attributes[InboxHold::KEY]
    refute @account.internal_attributes.key?(ReleaseRecord::KEY)
    assert_raises(InboxHold::Held) { InboxHold.with_inbox(@inboxes.last, now: now) {} }
    assert_equal stopped, inbox_hold(clock: -> { now + 1.minute })
    assert_equal 1, Toybaco::GrowthInboxRelease.where(account_id: @account.id).count
  end

  def test_next_stop_refuses_unarchived_or_corrupt_predecessor_without_erasing_the_release
    prepare_inbox_release
    release_inbox
    _, now = confirmed_next_inbox_generation
    attrs = @account.internal_attributes.deep_dup
    changed = attrs[InboxHold::KEY].merge('confirmed_at' => NOW.to_i - 1)
    changed['receipt_hash'] = Toybaco::Growth::RetentionSnapshot.fingerprint(changed.except('receipt_hash'))
    @account.update!(internal_attributes: attrs.merge(InboxHold::KEY => changed))
    assert_raises(InboxHold::Invalid) { inbox_hold(clock: -> { now }) }
    assert_equal attrs[ReleaseRecord::KEY], @account.reload.internal_attributes[ReleaseRecord::KEY]
    @account.update!(internal_attributes: attrs.except(FreeRecord::KEY))
    assert_raises(InboxHold::Invalid) { inbox_hold(clock: -> { now }) }
    assert_equal attrs[ReleaseRecord::KEY], @account.reload.internal_attributes[ReleaseRecord::KEY]
  end

end

# Exercise the actual authenticated administrative update, including a repeated
# suspended value that does not trigger an ActiveRecord status-change callback.
require 'devise/test/integration_helpers'

class ToybacoBillingAdministrativeStatusRuntimeTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  self.use_transactional_tests = false

  def setup
    @account = FactoryBot.create(:account, status: 'suspended')
    @administrator = FactoryBot.create(:super_admin)
    @account.update!(internal_attributes: { 'toybaco_billing_suspended' => true,
      'toybaco_subscription_status' => 'canceled', 'unrelated_marker' => 'preserved' })
  end

  def teardown
    @platform&.destroy!
    @created_platform_account&.destroy!
    @account.destroy!
    @administrator.destroy!
    Current.reset
  end

  def update_status(**attributes)
    ViteRuby.instance.stub(:dev_server_running?, true) do
      patch "/super_admin/accounts/#{@account.id}", params: { account: attributes },
            env: { 'action_dispatch.show_exceptions' => :none }
    end
  end

  def test_repeated_admin_suspension_clears_automatic_resume_ownership_and_preserves_history
    sign_in @administrator, scope: :super_admin
    update_status(status: 'suspended', suspension_category: 'other', suspension_reason: 'Fixture administrative suspension')
    assert_response :redirect
    assert_equal 'suspended', @account.reload.status
    assert_equal false, @account.internal_attributes['toybaco_billing_suspended']
    assert_equal 'preserved', @account.internal_attributes['unrelated_marker']
    assert_equal 'other', @account.suspension_history.last['category']
    assert_equal 'Fixture administrative suspension', @account.suspension_history.last['reason']
    update_status(status: 'active')
    assert_response :redirect
    assert_equal 'active', @account.reload.status
    assert_equal false, @account.internal_attributes['toybaco_billing_suspended']
    assert_equal 1, @account.suspension_history.size
  end

  def test_edit_without_status_does_not_change_billing_resume_ownership
    sign_in @administrator, scope: :super_admin
    update_status(name: 'Fixture renamed store')
    assert_response :redirect
    assert_equal 'Fixture renamed store', @account.reload.name
    assert_equal true, @account.internal_attributes['toybaco_billing_suspended']
    assert_equal 'suspended', @account.status
  end

  def test_unsaved_invalid_admin_change_does_not_clear_billing_ownership
    sign_in @administrator, scope: :super_admin
    original = @account.internal_attributes.deep_dup
    update_status(name: '', status: 'suspended', suspension_category: 'other', suspension_reason: 'Fixture administrative suspension')
    assert_response :unprocessable_entity
    assert_equal original, @account.reload.internal_attributes
    assert_equal 'suspended', @account.status
  end

  def test_unauthenticated_update_cannot_clear_billing_ownership
    original = @account.internal_attributes.deep_dup
    update_status(status: 'suspended', suspension_category: 'other', suspension_reason: 'Fixture administrative suspension')
    assert_response :redirect
    assert_includes response.location, '/super_admin/sign_in'
    assert_equal original, @account.reload.internal_attributes
  end
  def platform_request(attributes, allowed: true)
    @platform ||= FactoryBot.create(:platform_app)
    if allowed
      @platform.platform_app_permissibles.find_or_create_by!(permissible: @account)
    end
    patch "/platform/api/v1/accounts/#{@account.id}", params: attributes,
      headers: { api_access_token: @platform.access_token.token }, as: :json
  end

  def test_platform_repeated_numeric_suspension_clears_billing_resume_ownership
    platform_request({ status: 1 })
    assert_response :success
    assert_equal 'suspended', @account.reload.status
    assert_equal false, @account.internal_attributes['toybaco_billing_suspended']
    assert_equal 'preserved', @account.internal_attributes['unrelated_marker']
    platform_request({ status: 'active' })
    assert_response :success
    assert_equal 'active', @account.reload.status
    assert_equal false, @account.internal_attributes['toybaco_billing_suspended']
  end

  def test_platform_name_edit_preserves_billing_resume_ownership
    platform_request({ name: 'Platform fixture renamed' })
    assert_response :success
    assert_equal 'Platform fixture renamed', @account.reload.name
    assert_equal true, @account.internal_attributes['toybaco_billing_suspended']
  end

  def test_platform_invalid_update_rolls_back_billing_resume_ownership
    original = @account.internal_attributes.deep_dup
    platform_request({ name: '', status: 'suspended' })
    assert_response :unprocessable_entity
    assert_equal original, @account.reload.internal_attributes
  end

  def test_platform_without_store_permission_cannot_clear_billing_resume_ownership
    original = @account.internal_attributes.deep_dup
    platform_request({ status: 'suspended' }, allowed: false)
    assert_response :unauthorized
    assert_equal original, @account.reload.internal_attributes
  end

  def test_platform_account_creation_keeps_the_existing_status_behavior
    @platform = FactoryBot.create(:platform_app)
    post '/platform/api/v1/accounts', params: { name: 'Platform created fixture', status: 'suspended' },
      headers: { api_access_token: @platform.access_token.token }, as: :json
    assert_response :success
    @created_platform_account = Account.find(response.parsed_body.fetch('id'))
    assert_equal 'suspended', @created_platform_account.status
    refute @created_platform_account.internal_attributes.key?('toybaco_billing_suspended')
  end
end

class ToybacoGrowthRenewalTransitionRuntimeTest
  Dispatch = Toybaco::Growth::InboxDispatch
  DeliveryEpoch = Toybaco::Growth::InboxDeliveryEpoch

  def pending_reply(box = @inboxes.last, at: NOW - 1.minute, **options)
    travel_to at do
      conversation = create(:conversation, account: @account, inbox: box)
      create(:message, account: @account, inbox: box, conversation: conversation, message_type: :outgoing,
        sender: @owner, content: 'private queued reply fixture', **options)
    end
  end

  def serialized_dispatch(job)
    previous = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    assert job.enqueue
    JSON.parse(JSON.generate(job.serialize))
  ensure
    ActiveJob::Base.queue_adapter = previous
  end

  def perform_without_provider(serialized)
    calls = []
    service = Object.new
    service.define_singleton_method(:perform) { calls << :delivered }
    Messages::SendEmailNotificationService.stub(:new, ->(**) { service }) do
      ActiveJob::Base.deserialize(serialized).perform_now
    end
    calls
  end

  def retry_via_http(message, user: @owner)
    previous = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! 'app.example.com'
    session.post "/api/v1/accounts/#{@account.id}/conversations/#{message.conversation.display_id}/messages/#{message.id}/retry",
      headers: user.create_new_auth_token, as: :json
    result = ActiveJob::Base.queue_adapter.enqueued_jobs.find { |job| job['job_class'] == 'SendReplyJob' }
    [session.response.status, result && JSON.parse(JSON.generate(result.select { |key, _| key.is_a?(String) }))]
  ensure
    ActiveJob::Base.queue_adapter = previous
  end

  def test_queue_generation_is_serialized_and_old_jobs_cannot_restart_after_release
    message = pending_reply
    old = travel_to(NOW - 30.seconds) { serialized_dispatch(SendReplyJob.new(message.id)) }
    assert_nil old.dig(Dispatch::KEY, 'epoch')
    prepare_inbox_release
    release_inbox
    before = message.reload.attributes.slice('content', 'source_id', 'additional_attributes')
    travel_to NOW do
      assert_empty perform_without_provider(old)
      assert message.reload.failed?
      assert_includes message.content_attributes['external_error'], '再送'
      assert_equal before, message.attributes.slice('content', 'source_id', 'additional_attributes')
      assert_raises(Dispatch::Stale) { serialized_dispatch(SendReplyJob.new(message.id)) }
      assert_raises(Dispatch::Stale) { Dispatch.deliver(message) { flunk 'direct old dispatch' } }
    end
  end

  def test_native_retry_creates_new_job_and_old_job_cannot_overwrite_it
    message = pending_reply
    old = travel_to(NOW - 30.seconds) { serialized_dispatch(SendReplyJob.new(message.id)) }
    prepare_inbox_release
    release_inbox
    travel_to NOW do
      assert_empty perform_without_provider(old)
      status, fresh = retry_via_http(message)
      assert_equal 200, status
      assert fresh
      assert_equal @owner.id, fresh.dig(Dispatch::KEY, 'retry', 'actor_id')
      refute_nil fresh.dig(Dispatch::KEY, 'epoch')
      assert_empty perform_without_provider(old)
      refute message.reload.failed?, 'obsolete queue must not overwrite the explicit retry'
      assert_equal [:delivered], perform_without_provider(fresh)
      assert_nil ActiveSupport::IsolatedExecutionState[Dispatch::CONTEXT]
      assert_nil ActiveSupport::IsolatedExecutionState[Dispatch::RETRY_CONTEXT]
      assert_raises(Dispatch::Stale) { Dispatch.capture(message) }
    end
  end

  def test_queued_retry_rechecks_current_membership_before_provider
    message = pending_reply
    prepare_inbox_release
    release_inbox
    travel_to NOW do
      Dispatch.park!(message, DeliveryEpoch.read(message.inbox, now: NOW))
      status, job = retry_via_http(message)
      assert_equal 200, status
      assert job
      @account.account_users.where(user_id: @owner.id).delete_all
      assert_empty perform_without_provider(job)
      assert message.reload.failed?
      assert_equal 'private queued reply fixture', message.reload.content
    end
  end

  def test_old_jobs_leave_unknown_provider_attempts_and_provider_id_intact
    message = pending_reply
    old = travel_to(NOW - 30.seconds) { serialized_dispatch(SendReplyJob.new(message.id)) }
    prepare_inbox_release
    release_inbox
    travel_to NOW do
      %w[toybaco_gmail_send toybaco_microsoft_send].each do |provider_key|
        %w[preparing sending uncertain accepted].each do |state|
          message.update!(status: :sent, content_attributes: { provider_key => { 'state' => state, 'attempt_id' => 'fixture' } })
          before = message.reload.attributes
          assert_empty perform_without_provider(old)
          assert_equal before, message.reload.attributes
        end
      end
      message.update!(source_id: 'existing-provider-id', content_attributes: {})
      before = message.reload.attributes
      assert_empty perform_without_provider(old)
      assert_equal before, message.reload.attributes
    end
  end

  def test_kept_inbox_pending_work_and_new_released_replies_remain_sendable
    kept = pending_reply(@inboxes.first)
    old = travel_to(NOW - 30.seconds) { serialized_dispatch(SendReplyJob.new(kept.id)) }
    prepare_inbox_release
    release_inbox
    travel_to(NOW + 1.second) { assert_equal [:delivered], perform_without_provider(old) }
    message = pending_reply(at: NOW + 1.second)
    travel_to(NOW + 2.seconds) do
      assert_equal [:delivered], perform_without_provider(serialized_dispatch(SendReplyJob.new(message.id)))
      assert_equal :sent, Dispatch.deliver(message) { :sent }
    end
  end

  def test_legacy_queue_corrupt_snapshot_and_missing_epoch_fail_closed
    message = pending_reply
    old = travel_to(NOW - 30.seconds) { serialized_dispatch(SendReplyJob.new(message.id)) }
    prepare_inbox_release
    release_inbox
    travel_to NOW do
      [old.except(Dispatch::KEY), old.merge(Dispatch::KEY => false),
       old.merge(Dispatch::KEY => old[Dispatch::KEY].merge('message_id' => message.id + 1))].each do |job|
        assert_empty perform_without_provider(job)
      end
      attrs = @account.reload.internal_attributes.deep_dup
      # Inject malformed storage past the write guard; delivery must still reject it.
      @account.update_columns(internal_attributes: attrs.except(DeliveryEpoch::KEY))
      assert_raises(InboxHold::Invalid) { Dispatch.deliver(message) {} }
      @account.update_columns(internal_attributes: attrs.merge(DeliveryEpoch::KEY => attrs[DeliveryEpoch::KEY].merge('entries' => [])))
      assert_raises(InboxHold::Invalid) { Dispatch.deliver(message) {} }
    end
  end

  def test_browser_cannot_create_retry_metadata_and_scope_cleans_up
    message = pending_reply(additional_attributes: { Dispatch::RETRY_KEY => { 'nonce' => 'forged' }, 'fixture' => true })
    refute message.reload.additional_attributes.key?(Dispatch::RETRY_KEY)
    assert_equal true, message.additional_attributes['fixture']
    assert_raises(RuntimeError) { Dispatch.with_retry(message, @owner) { raise 'fixture error' } }
    assert_nil ActiveSupport::IsolatedExecutionState[Dispatch::RETRY_CONTEXT]
  end

  def test_delayed_notification_and_mailer_jobs_keep_original_generation
    message = pending_reply
    jobs = travel_to(NOW - 30.seconds) do
      [serialized_dispatch(ConversationReplyEmailJob.new(message.conversation_id, message.id)),
       serialized_dispatch(ActionMailer::MailDeliveryJob.new('ConversationReplyMailer', 'email_reply', 'deliver_now', args: [message])),
       serialized_dispatch(ActionMailer::MailDeliveryJob.new('ConversationReplyMailer', 'reply_with_summary', 'deliver_now', args: [message.conversation, message.id]))]
    end
    prepare_inbox_release
    release_inbox
    travel_to NOW do
      jobs.each { |job| assert_instance_of Dispatch::Stale, ActiveJob::Base.deserialize(job).perform_now }
      mailer = ConversationReplyMailer.new
      mailer.instance_variable_set(:@conversation, message.conversation)
      mailer.instance_variable_set(:@message, message)
      mailer.instance_variable_set(:@_action_name, 'email_reply')
      assert_raises(Dispatch::Stale) { mailer.run_callbacks(:deliver) { flunk 'SMTP must not start' } }
    end
  end

  def test_retry_context_propagates_to_mail_but_never_to_another_message
    message, other = pending_reply, pending_reply
    prepare_inbox_release
    release_inbox
    travel_to NOW do
      Dispatch.park!(message, DeliveryEpoch.read(message.inbox, now: NOW))
      status, serialized = retry_via_http(message)
      assert_equal 200, status
      snapshot = serialized.fetch(Dispatch::KEY)
      mail_job = Dispatch.deliver(message, snapshot: snapshot) do
        serialized_dispatch(ConversationReplyEmailJob.new(message.conversation_id, message.id))
      end
      assert_equal snapshot, mail_job[Dispatch::KEY]
      Dispatch.deliver(message, snapshot: snapshot) do
        assert_raises(Dispatch::Stale) { serialized_dispatch(SendReplyJob.new(other.id)) }
      end
      assert_nil ActiveSupport::IsolatedExecutionState[Dispatch::CONTEXT]
    end
  end

  def test_new_hold_rotates_persisted_dispatch_generation
    message = pending_reply
    prepare_inbox_release
    release_inbox
    first = @account.reload.internal_attributes.fetch(DeliveryEpoch::KEY)
    _, now = confirmed_next_inbox_generation
    inbox_hold(clock: -> { now })
    second = @account.reload.internal_attributes.fetch(DeliveryEpoch::KEY)
    refute_equal first['hold_hash'], second['hold_hash']
    entry = second['entries'].find { |item| item['inbox_id'] == message.inbox_id.to_s }
    assert_equal (now.to_r * 1_000_000).to_i, entry['stopped_at_us']
    refute_equal first['entries'].first['transition_id'], entry['transition_id']
    assert_equal message.inbox_id.to_s, entry['inbox_id']
  end

  def test_dispatch_keeps_shared_database_fence_until_provider_finishes
    prepare_inbox_release
    release_inbox
    message = pending_reply(at: NOW + 1.second)
    entered, finish = Queue.new, Queue.new
    travel_to(NOW + 2.seconds) do
      worker = Thread.new do
        Account.connection_pool.with_connection do
          Dispatch.deliver(Message.find(message.id)) { entered << true; finish.pop }
        end
      end
      Timeout.timeout(5) { entered.pop }
      assert_raises(InboxHold::Busy) { InboxHold.with_fence(@account.id, exclusive: true) {} }
      finish << true
      raise 'dispatch fence timeout' unless worker.join(5)
      worker.value
      assert_equal :released, InboxHold.with_fence(@account.id, exclusive: true) { :released }
    ensure
      finish << true
      worker&.join(5)
    end
  end
end

class ToybacoGrowthRenewalTransitionRuntimeTest
  def test_native_retry_never_clears_existing_or_unknown_provider_receipts_after_release
    message = pending_reply
    prepare_inbox_release
    release_inbox
    travel_to NOW do
      [{ 'toybaco_gmail_send' => { 'state' => 'uncertain', 'attempt_id' => 'saved' } },
       { 'toybaco_microsoft_send' => { 'state' => 'preparing', 'attempt_id' => 'saved' } },
       { 'toybaco_microsoft_send' => 'malformed-provider-receipt' },
       { 'toybaco_gmail_send' => { 'state' => 'unknown-provider-state' } },
       { 'toybaco_gmail_send' => nil }, { 'toybaco_microsoft_send' => false }].each do |saved|
        message.update!(status: :failed, content_attributes: saved)
        before = message.reload.attributes
        status, job = retry_via_http(message)
        assert_equal 200, status
        assert_nil job
        assert_equal before, message.reload.attributes
      end
      message.update!(status: :failed, source_id: 'existing-provider-id', content_attributes: {})
      before = message.reload.attributes
      status, job = retry_via_http(message)
      assert_equal 200, status
      assert_nil job
      assert_equal before, message.reload.attributes
    end
  end
end

class ToybacoGrowthRenewalTransitionRuntimeTest
  def test_hold_between_message_commit_and_enqueue_preserves_reply_as_failed_without_sending
    prepare_inbox_hold
    previous = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    capture = Dispatch.method(:capture)
    saved = nil
    travel_to NOW do
      Dispatch.stub(:capture, lambda { |message|
        saved = message
        refute Account.connection.transaction_open?, 'the message must commit before the queue callback'
        committed = Thread.new do
          Account.connection_pool.with_connection { Message.exists?(message.id) }
        end
        assert committed.join(5), 'committed-message read timed out'
        assert committed.value
        inbox_hold
        capture.call(message)
      }) do
        assert_raises(Dispatch::Stale) do
          conversation = create(:conversation, account: @account, inbox: @inboxes.last)
          create(:message, account: @account, inbox: @inboxes.last, conversation: conversation,
            message_type: :outgoing, sender: @owner, content: 'private queued reply fixture')
        end
      end
      assert saved.reload.failed?
      assert_equal 'private queued reply fixture', saved.content
      assert_nil saved.source_id
      refute ActiveJob::Base.queue_adapter.enqueued_jobs.any? { |job| job['job_class'] == 'SendReplyJob' }
      assert_raises(InboxHold::Held) { InboxHold.with_inbox(saved.inbox) {} }
    end
  ensure
    ActiveJob::Base.queue_adapter = previous
  end
end

class ToybacoGrowthRenewalTransitionRuntimeTest
  NotificationLease = Toybaco::Growth::InboxNotification

  def notification_inbox(message)
    message.inbox.channel.update!(continuity_via_email: true)
    message.conversation.contact.update!(email: 'queued-mail-fixture@example.invalid')
    message.conversation.update!(contact_last_seen_at: nil)
  end

  def notification_key(message, snapshot)
    key = NotificationLease.key(message.conversation_id, snapshot)
    (@notification_keys ||= []) << key
    key
  end

  def with_notification_queue
    previous = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    yield ActiveJob::Base.queue_adapter.enqueued_jobs
  ensure
    ActiveJob::Base.queue_adapter = previous
  end

  def notification_jobs(queue, name = 'ConversationReplyEmailJob')
    queue.select { |job| job['job_class'] == name }.map { |job| JSON.parse(JSON.generate(job.select { |key, _| key.is_a?(String) })) }
  end

  def test_numeric_legacy_notification_lease_does_not_block_retry_or_erase_its_new_lease
    message = pending_reply
    old = travel_to(NOW - 30.seconds) { serialized_dispatch(ConversationReplyEmailJob.new(message.conversation_id, message.id)) }
    notification_inbox(message)
    prepare_inbox_release
    release_inbox
    travel_to NOW do
      Dispatch.park!(message, DeliveryEpoch.read(message.inbox, now: NOW))
      status, retry_job = retry_via_http(message)
      assert_equal 200, status
      legacy_key = format(Redis::Alfred::CONVERSATION_MAILER_KEY, conversation_id: message.conversation_id)
      (@notification_keys ||= []) << legacy_key
      Redis::Alfred.set(legacy_key, message.id, ex: 3600)
      notification_key(message, retry_job.fetch(Dispatch::KEY))
      with_notification_queue do |queue|
        ActiveJob::Base.deserialize(retry_job).perform_now
        child = notification_jobs(queue).fetch(0)
        assert_equal 1, notification_jobs(queue).size
        key = notification_key(message, child.fetch(Dispatch::KEY))
        assert_equal child['job_id'], Redis::Alfred.get(key)
        assert_instance_of Dispatch::Stale, ActiveJob::Base.deserialize(old).perform_now
        assert_equal child['job_id'], Redis::Alfred.get(key)
        assert_equal message.id.to_s, Redis::Alfred.get(legacy_key)
        ActiveJob::Base.deserialize(child).perform_now
        assert_equal 1, notification_jobs(queue, 'ActionMailer::MailDeliveryJob').size
        assert_nil Redis::Alfred.get(key)
        ActiveJob::Base.deserialize(child).perform_now
        assert_equal 1, notification_jobs(queue, 'ActionMailer::MailDeliveryJob').size
      end
    end
  end

  def test_generation_notification_lease_coalesces_messages_and_old_job_cannot_delete_new_owner
    prepare_inbox_release
    release_inbox
    message = pending_reply(at: NOW + 1.second)
    notification_inbox(message)
    travel_to(NOW + 2.seconds) do
      other = create(:message, account: @account, inbox: message.inbox, conversation: message.conversation,
        message_type: :outgoing, sender: @owner, content: 'second fresh notification fixture')
      notification_key(message, Dispatch.capture(message))
      with_notification_queue do |queue|
        Messages::SendEmailNotificationService.new(message: message).perform
        Messages::SendEmailNotificationService.new(message: other).perform
        child = notification_jobs(queue).fetch(0)
        assert_equal 1, notification_jobs(queue).size
        key = notification_key(message, child.fetch(Dispatch::KEY))
        assert_equal child['job_id'], Redis::Alfred.get(key)
        assert_operator Redis::Alfred.ttl(key), :>, 3500
        newer = SecureRandom.uuid
        Redis::Alfred.set(key, newer, ex: 3600)
        ActiveJob::Base.deserialize(child).perform_now
        assert_empty notification_jobs(queue, 'ActionMailer::MailDeliveryJob')
        assert_equal newer, Redis::Alfred.get(key)
      end
    end
  end

  def test_generation_notification_redis_claim_is_atomic_across_database_connections
    prepare_inbox_release
    release_inbox
    message = pending_reply(at: NOW + 1.second)
    notification_inbox(message)
    travel_to(NOW + 2.seconds) do
      key = notification_key(message, Dispatch.capture(message))
      with_notification_queue do |queue|
        threads = 2.times.map do
          Thread.new do
            Account.connection_pool.with_connection do
              Messages::SendEmailNotificationService.new(message: Message.find(message.id)).perform
            end
          end
        end
        threads.each { |thread| assert thread.join(5); thread.value }
        children = notification_jobs(queue)
        assert_equal 1, children.size
        assert_equal children.first['job_id'], Redis::Alfred.get(key)
      ensure
        threads&.each do |thread|
          thread.kill if thread.alive?
          thread.join
        end
      end
    end
  end

  def test_duplicate_notification_workers_cannot_enqueue_two_delivery_jobs
    prepare_inbox_release
    release_inbox
    message = pending_reply(at: NOW + 1.second)
    notification_inbox(message)
    travel_to(NOW + 2.seconds) do
      notification_key(message, Dispatch.capture(message))
      with_notification_queue do |queue|
        Messages::SendEmailNotificationService.new(message: message).perform
        child = notification_jobs(queue).fetch(0)
        first = ActiveJob::Base.deserialize(child)
        original = first.method(:toybaco_enqueue_mail)
        entered, finish = Queue.new, Queue.new
        first.stub(:toybaco_enqueue_mail, ->(*args) { entered << true; finish.pop; original.call(*args) }) do
          worker = Thread.new do
            Account.connection_pool.with_connection { first.perform_now }
          end
          assert Timeout.timeout(5) { entered.pop }
          key = notification_key(message, child.fetch(Dispatch::KEY))
          assert_equal NotificationLease.dispatch_value(child['job_id']), Redis::Alfred.get(key)
          ActiveJob::Base.deserialize(child).perform_now
          assert_empty notification_jobs(queue, 'ActionMailer::MailDeliveryJob')
          assert_equal NotificationLease.dispatch_value(child['job_id']), Redis::Alfred.get(key)
          finish << true
          assert worker.join(5)
          worker.value
          assert_equal 1, notification_jobs(queue, 'ActionMailer::MailDeliveryJob').size
          assert_nil Redis::Alfred.get(key)
        ensure
          finish << true
          worker&.kill if worker&.alive?
          worker&.join
        end
      end
    end
  end

  def test_uncertain_notification_enqueue_keeps_claim_and_does_not_automatically_resend
    prepare_inbox_release
    release_inbox
    message = pending_reply(at: NOW + 1.second)
    notification_inbox(message)
    travel_to(NOW + 2.seconds) do
      notification_key(message, Dispatch.capture(message))
      with_notification_queue do |queue|
        Messages::SendEmailNotificationService.new(message: message).perform
        child = notification_jobs(queue).fetch(0)
        first = ActiveJob::Base.deserialize(child)
        original = first.method(:toybaco_enqueue_mail)
        first.stub(:toybaco_enqueue_mail, ->(*args) { original.call(*args); raise IOError, 'fixture queue acknowledgement lost' }) do
          assert_raises(IOError) { first.perform_now }
        end
        key = notification_key(message, child.fetch(Dispatch::KEY))
        assert_equal NotificationLease.dispatch_value(child['job_id']), Redis::Alfred.get(key)
        assert_equal 1, notification_jobs(queue, 'ActionMailer::MailDeliveryJob').size
        ActiveJob::Base.deserialize(child).perform_now
        assert_equal 1, notification_jobs(queue, 'ActionMailer::MailDeliveryJob').size
        assert_equal NotificationLease.dispatch_value(child['job_id']), Redis::Alfred.get(key)
      end
    end
  end

  def with_rendering_smtp
    previous = ENV['SMTP_ADDRESS']
    ENV['SMTP_ADDRESS'] = 'smtp.fixture.invalid'
    yield
  ensure
    previous ? ENV['SMTP_ADDRESS'] = previous : ENV.delete('SMTP_ADDRESS')
  end

  def mail_text(mail)
    mail.multipart? ? mail.parts.map(&:decoded).join("\n") : mail.body.decoded
  end

  def test_explicit_retry_renders_only_selected_reply_and_uses_its_recipient_fields
    message = pending_reply(content_attributes: { 'to_emails' => 'selected-fixture@example.invalid' })
    travel_to(NOW - 30.seconds) do
      create(:message, account: @account, inbox: message.inbox, conversation: message.conversation,
        message_type: :outgoing, sender: @owner, content: 'UNSELECTED-HELD-REPLY',
        content_attributes: { 'to_emails' => 'not-selected@example.invalid' })
    end
    notification_inbox(message)
    prepare_inbox_release
    release_inbox
    travel_to NOW do
      Dispatch.park!(message, DeliveryEpoch.read(message.inbox, now: NOW))
      status, retry_job = retry_via_http(message)
      assert_equal 200, status
      # The stock retry clears transient content fields; the displayed recipient
      # is the contact, never the later held reply's arbitrary recipient fields.
      with_rendering_smtp do
        %i[reply_with_summary reply_without_summary].each do |method|
          mail = Dispatch.deliver(message, snapshot: retry_job.fetch(Dispatch::KEY)) do
            ConversationReplyMailer.with(account: @account).public_send(method, message.conversation, message.id).message
          end
          assert_includes mail_text(mail), 'private queued reply fixture'
          refute_includes mail_text(mail), 'UNSELECTED-HELD-REPLY'
          refute_includes Array(mail.to), 'not-selected@example.invalid'
          assert_includes Array(mail.to), 'queued-mail-fixture@example.invalid'
        end
      end
    end
  end

  def test_new_notification_summary_omits_held_replies_but_keeps_delivered_recap
    old = pending_reply
    old.update!(content: 'UNSENT-RECAP-REPLY')
    travel_to(NOW - 30.seconds) do
      create(:message, account: @account, inbox: old.inbox, conversation: old.conversation,
        message_type: :outgoing, sender: @owner, content: 'DELIVERED-RECAP-REPLY', source_id: 'fixture-sent', status: :delivered)
    end
    notification_inbox(old)
    prepare_inbox_release
    release_inbox
    travel_to(NOW + 1.second) do
      fresh = create(:message, account: @account, inbox: old.inbox, conversation: old.conversation,
        message_type: :outgoing, sender: @owner, content: 'NEW-AUTHORIZED-REPLY')
      with_rendering_smtp do
        mail = Dispatch.deliver(fresh) do
          ConversationReplyMailer.with(account: @account).reply_with_summary(fresh.conversation, fresh.id).message
        end
        assert_includes mail_text(mail), 'NEW-AUTHORIZED-REPLY'
        assert_includes mail_text(mail), 'DELIVERED-RECAP-REPLY'
        refute_includes mail_text(mail), 'UNSENT-RECAP-REPLY'
      end
    end
  end
end

class ToybacoGrowthRenewalTransitionRuntimeTest
  ContractBoundary = Toybaco::Growth::InboxContractBoundary

  def with_other_inbox_sender
    ready, finish = Queue.new, Queue.new
    worker = Thread.new do
      Account.connection_pool.with_connection do
        InboxHold.with_inbox(@inboxes.last, now: NOW) do
          ready << true
          finish.pop
        end
      end
    end
    Timeout.timeout(5) { ready.pop }
    yield
  ensure
    finish << true if finish
    worker&.join(5)
    worker&.value
  end

  def test_contract_restore_requires_new_explicit_release_and_never_restores_old_queue
    prepare_inbox_release
    first_revision = release_service.read['revision']
    first = release_inbox(revision: first_revision)
    message = pending_reply(at: NOW + 1.second)
    queued = travel_to(NOW + 1.second) { serialized_dispatch(SendReplyJob.new(message.id)) }
    before = @account.reload.internal_attributes.deep_dup
    preserved = @inboxes.map { |box| box.channel.reload.attributes }
    later = NOW + 2.seconds
    travel_to later do
      @account.update!(internal_attributes: before.merge('toybaco_subscription_id' => 'sub_changed'))
      assert_raises(InboxHold::Held) { InboxHold.with_inbox(@inboxes.last) {} }
      @account.update!(internal_attributes: @account.reload.internal_attributes.merge('toybaco_subscription_id' => 'sub_repurchase'))
      refute @account.reload.internal_attributes.key?(ReleaseRecord::KEY)
      refute_equal before[DeliveryEpoch::KEY], @account.internal_attributes[DeliveryEpoch::KEY]
      assert_raises(InboxHold::Held) { InboxHold.with_inbox(@inboxes.last) {} }
      assert_equal first, release_service(now: later).call(inbox_ids: [@inboxes.last.id.to_s], revision: first_revision, request_id: first['request_id'])
      refute @account.reload.internal_attributes.key?(ReleaseRecord::KEY)
      service = release_service(now: later)
      receipt = service.call(inbox_ids: [@inboxes.last.id.to_s], revision: service.read['revision'], request_id: 'b' * 64)
      assert_equal receipt, ReleaseRecord.current(@account.id, @account.reload.internal_attributes, before[InboxHold::KEY], now: later)
      assert_empty perform_without_provider(queued)
      assert message.reload.failed?
      status, retry_job = retry_via_http(message)
      assert_equal 200, status
      assert_equal [:delivered], perform_without_provider(retry_job)
    end
    assert_equal preserved, @inboxes.map { |box| box.channel.reload.attributes }
    assert_equal before[InboxHold::KEY], @account.reload.internal_attributes[InboxHold::KEY]
    assert_equal first, ReleaseRecord.find!(@account.id, first['request_id'], now: later)
  end

  def test_contract_boundary_serializes_sync_with_delivery_and_rolls_back_outer_account_transaction
    prepare_inbox_release
    release_inbox
    before = @account.reload.internal_attributes.deep_dup
    provider = @release_provider.sub.deep_dup.merge('status' => 'canceled')
    client = Struct.new(:sub) { def retrieve_subscription(*) = sub.deep_dup }.new(provider)
    disabled = []
    with_other_inbox_sender do
      Toybaco::PostizSync.stub(:disable_account!, ->(**) { disabled << true }) do
        assert_raises(InboxHold::Busy) do
          Timeout.timeout(3) do
            travel_to NOW do
              @account.with_lock do
                @account.update!(name: 'transaction must roll back')
                Toybaco::SubscriptionSync.new(client: client).call(@account, subscription_id: 'sub_repurchase')
              end
            end
          end
        end
      end
    end
    assert_empty disabled, 'the nonblocking fence must run before lifecycle external changes'
    refute_equal 'transaction must roll back', @account.reload.name
    assert_equal before, @account.internal_attributes
    travel_to NOW do
      assert_equal 'applied', Toybaco::SubscriptionSync.new(client: client).call(@account, subscription_id: 'sub_repurchase')
      assert_equal 'suspended', @account.reload.status
      refute @account.internal_attributes.key?(ReleaseRecord::KEY)
    end
  end

  def test_subscription_sync_repayment_does_not_restore_revoked_inbox_release
    prepare_inbox_release
    release_inbox
    old = @account.reload.internal_attributes.deep_dup
    @release_provider.sub['status'] = 'canceled'
    travel_to NOW do
      sync = Toybaco::SubscriptionSync.new(client: @release_provider)
      assert_equal 'applied', sync.call(@account, subscription_id: 'sub_repurchase')
      stopped = @account.reload.internal_attributes[DeliveryEpoch::KEY]
      assert_equal 'suspended', @account.status
      @release_provider.sub['status'] = 'active'
      assert_equal 'applied', sync.call(@account, subscription_id: 'sub_repurchase')
      assert_equal 'active', @account.reload.status
      assert_equal old['toybaco_contract'], @account.internal_attributes['toybaco_contract']
      refute @account.internal_attributes.key?(ReleaseRecord::KEY)
      assert_equal stopped, @account.internal_attributes[DeliveryEpoch::KEY]
      assert_raises(InboxHold::Held) { InboxHold.with_inbox(@inboxes.last) {} }
    end
  end

  def test_unchanged_verified_sync_and_unrelated_account_edits_preserve_release_and_epoch
    prepare_inbox_release
    release_inbox
    old = @account.reload.internal_attributes.slice(*ContractBoundary::PROTECTED)
    travel_to NOW do
      2.times { assert_equal 'applied', Toybaco::SubscriptionSync.new(client: @release_provider).call(@account, subscription_id: 'sub_repurchase') }
      with_other_inbox_sender do
        @account.update!(name: 'Updated store', internal_attributes: @account.reload.internal_attributes.merge('fixture_unrelated' => 1))
      end
      @release_provider.sub['status'] = 'past_due'
      assert_equal 'applied', Toybaco::SubscriptionSync.new(client: @release_provider).call(@account, subscription_id: 'sub_repurchase')
      assert_equal 'active', @account.reload.status
      assert_equal 'past_due', @account.internal_attributes['toybaco_subscription_status']
      assert_equal old, @account.internal_attributes.slice(*ContractBoundary::PROTECTED)
      assert_equal :allowed, InboxHold.with_inbox(@inboxes.last) { :allowed }
    end
  end

  def test_entitlement_change_revoke_rolls_back_with_failed_caller_transaction
    prepare_inbox_release
    release_inbox
    old = @account.reload.internal_attributes.deep_dup
    changed = old['toybaco_contract'].deep_dup.merge('reference_price_id' => 'price_changed')
    travel_to NOW do
      assert_raises(RuntimeError) do
        @account.with_lock do
          Toybaco::Entitlements.apply!(@account, changed, subscription_id: 'sub_repurchase')
          refute @account.internal_attributes.key?(ReleaseRecord::KEY)
          raise 'fixture later writer failure'
        end
      end
      assert_equal old, @account.reload.internal_attributes
      assert_equal :allowed, InboxHold.with_inbox(@inboxes.last) { :allowed }
      Toybaco::Entitlements.apply!(@account, changed, subscription_id: 'sub_repurchase')
      refute @account.reload.internal_attributes.key?(ReleaseRecord::KEY)
      assert_raises(InboxHold::Held) { InboxHold.with_inbox(@inboxes.last) {} }
    end
  end

  def test_stale_account_json_and_historical_pointer_cannot_restore_revoked_generation
    prepare_inbox_release
    receipt = release_inbox
    stale = Account.find(@account.id)
    old = stale.internal_attributes.deep_dup
    travel_to NOW do
      @account.update!(internal_attributes: old.merge('toybaco_stripe_customer_id' => 'cus_changed'))
      saved = @account.reload.internal_attributes.deep_dup
      assert_raises(InboxHold::Invalid) { stale.update!(internal_attributes: old.merge('fixture_unrelated' => 2)) }
      assert_equal saved, @account.reload.internal_attributes
      assert_raises(InboxHold::Invalid) do
        @account.update!(internal_attributes: saved.merge(ReleaseRecord::KEY => ReleaseRecord.reference(receipt)))
      end
      @account.reload
      assert_raises(InboxHold::Invalid) { @account.update!(internal_attributes: saved.merge(DeliveryEpoch::KEY => old[DeliveryEpoch::KEY])) }
      assert_equal saved, @account.reload.internal_attributes
      assert_nil ActiveSupport::IsolatedExecutionState[ContractBoundary::CONTEXT]
    end
  end

  def test_purchase_binding_fields_revoke_without_automatic_regrant
    prepare_inbox_release
    travel_to NOW do
      changes = [ { 'toybaco_stripe_customer_id' => 'cus_changed' },
        { 'toybaco_growth_purchase' => @account.internal_attributes['toybaco_growth_purchase'].merge('nonce' => 'd' * 48) },
        { 'toybaco_growth_purchase' => @account.internal_attributes['toybaco_growth_purchase'].merge('state' => 'pending') },
        { 'toybaco_growth_purchase' => @account.internal_attributes['toybaco_growth_purchase'].merge('livemode' => true) } ]
      changes.each_with_index do |change, index|
        service = release_service
        service.call(inbox_ids: [@inboxes.last.id.to_s], revision: service.read['revision'], request_id: (index + 1).to_s * 64)
        before = @account.reload.internal_attributes.deep_dup
        @account.update!(internal_attributes: before.merge(change))
        refute @account.reload.internal_attributes.key?(ReleaseRecord::KEY)
        current = @account.internal_attributes.deep_dup
        refute_equal before[DeliveryEpoch::KEY], current[DeliveryEpoch::KEY]
        restored = current.merge(before.slice(*change.keys)).except(*(change.keys - before.keys))
        @account.update!(internal_attributes: restored)
        assert_raises(InboxHold::Held) { InboxHold.with_inbox(@inboxes.last) {} }
      end
    end
  end

  def test_exclusive_writer_fence_survives_nested_savepoint_and_rejects_parallel_sender_until_commit
    prepare_inbox_release
    release_inbox
    outcomes = Queue.new
    travel_to NOW do
      @account.with_lock do
        Account.transaction(requires_new: true) do
          @account.update!(internal_attributes: @account.internal_attributes.merge('toybaco_subscription_id' => 'sub_changed'))
        end
        worker = Thread.new do
          Account.connection_pool.with_connection do
            outcomes << assert_raises(InboxHold::Busy) { InboxHold.with_inbox(@inboxes.last) {} }.class.name
          end
        end
        worker.join(5)
        worker.value
        assert_equal 'Toybaco::Growth::InboxRetention::Busy', outcomes.pop
      end
      assert_raises(InboxHold::Held) { InboxHold.with_inbox(@inboxes.last) {} }
    end
  end
end

class ToybacoGrowthRenewalTransitionRuntimeTest
  def test_billing_and_purchase_http_return_retryable_errors_for_contract_writer_conflicts
    previous = ENV['TOYBACO_STRIPE_KEY']
    ENV['TOYBACO_STRIPE_KEY'] = 'fixture_no_network'
    before = @account.reload.attributes
    reader = Struct.new(:user).new(@owner)
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! 'app.example.com'
    paths = [['/toybaco/billing/change_refresh', Toybaco::Checkout::PlanChange, 503],
             ['/toybaco/growth/purchase/refresh', Toybaco::Growth::PurchaseSession, 409]]
    Toybaco::Oidc::SessionReader.stub(:new, ->(*) { reader }) do
      [InboxHold::Busy, InboxHold::Invalid].each do |error|
        service = Object.new
        service.define_singleton_method(:refresh) { raise error }
        service.define_singleton_method(:refresh!) { raise error }
        paths.each do |path, klass, expected|
          klass.stub(:new, ->(*) { service }) do
            session.post "#{path}?account_id=#{@account.id}", params: {},
              headers: { 'Origin' => 'http://app.example.com', 'Sec-Fetch-Site' => 'same-origin' }, as: :json
          end
          assert_equal expected, session.response.status
          assert session.response.parsed_body['error'].is_a?(String)
          refute_includes session.response.body, error.name
          assert_equal 'no-store', session.response.headers['Cache-Control']
        end
      end
      reader.user = nil
      session.post "/toybaco/growth/purchase/refresh?account_id=#{@account.id}", params: {},
        headers: { 'Origin' => 'http://app.example.com' }, as: :json
      assert_equal 401, session.response.status
    end
    assert_equal before, @account.reload.attributes
  ensure
    previous ? ENV['TOYBACO_STRIPE_KEY'] = previous : ENV.delete('TOYBACO_STRIPE_KEY')
  end
end

require Rails.root.join('lib/toybaco/subscription_reconciliation/execution')

module ToybacoSubscriptionSyncFixtureCleanup
  def teardown
    Toybaco::SubscriptionSyncRequest.where(id: Array(@sync_receipts)).delete_all
    super
  end
end
ToybacoGrowthRenewalTransitionRuntimeTest.prepend(ToybacoSubscriptionSyncFixtureCleanup)

class ToybacoGrowthRenewalTransitionRuntimeTest
  Reconciliation = Toybaco::SubscriptionReconciliation
  SyncRequest = Toybaco::SubscriptionSyncRequest

  def accept_sync(id = 'sub_repurchase', at: NOW, mode: 'test')
    record = Toybaco::SubscriptionReconciliationJob.stub(:perform_later, ->(*) { true }) do
      Reconciliation.request!(id, mode: mode, now: at)
    end
    (@sync_receipts ||= []) << record.id
    record
  end

  def execute_sync(record, at: NOW, client: @release_provider, mode: 'test')
    travel_to(at) { Reconciliation::Execution.new(record, client: client, now: at, environment: { 'TOYBACO_STRIPE_MODE' => mode }).call }
  end

  def test_durable_sync_commits_before_provider_and_retries_sender_conflict_after_full_rollback
    prepare_inbox_release
    release_inbox
    old = @account.reload.attributes
    record = accept_sync
    @release_provider.sub['status'] = 'canceled'
    @release_provider.callback = lambda do
      Account.connection_pool.with_connection do |connection|
        # A separate PostgreSQL session must observe the committed claim.
        other = Thread.new do
          Account.connection_pool.with_connection do
            row = SyncRequest.find(record.id)
            assert_equal ['running', 1], [row.state, row.attempts]
          end
        end
        other.join(5)
        other.value
      end
    end
    with_other_inbox_sender { assert_equal 'pending', execute_sync(record) }
    assert_equal old, @account.reload.attributes
    assert_equal [1, 0, 'writer_busy'], record.reload.attributes.values_at('requested_revision', 'completed_revision', 'result')
    assert_equal NOW + 30, record.next_attempt_at
    @release_provider.callback = nil
    assert_equal 'completed', execute_sync(record, at: NOW + 30)
    assert_equal 'suspended', @account.reload.status
    assert_equal [1, 2], [record.reload.completed_revision, record.attempts]
    assert_equal 'completed', execute_sync(record, at: NOW + 60)
    assert_equal 2, record.reload.attempts
  end

  def test_durable_sync_request_during_processing_keeps_new_revision_pending
    prepare_inbox_release
    record = accept_sync
    ready, finish = Queue.new, Queue.new
    worker = nil
    @release_provider.callback = -> { ready << true; finish.pop }
    travel_to NOW do
      worker = Thread.new do
        Account.connection_pool.with_connection do
          Reconciliation::Execution.new(SyncRequest.find(record.id), client: @release_provider, now: NOW,
            environment: { 'TOYBACO_STRIPE_MODE' => 'test' }).call
        end
      end
      Timeout.timeout(5) { ready.pop }
      duplicate = accept_sync(at: NOW + 1)
      assert_equal record.id, duplicate.id
      assert_equal 2, duplicate.requested_revision
      assert_equal 'busy', Reconciliation::Execution.new(SyncRequest.find(record.id), client: @release_provider, now: NOW,
        environment: { 'TOYBACO_STRIPE_MODE' => 'test' }).call
      finish << true
      worker.join(10)
      assert_equal 'pending', worker.value
    end
    assert_equal [2, 1, 1], record.reload.attributes.values_at('requested_revision', 'completed_revision', 'attempts')
    @release_provider.callback = nil
    assert_equal 'completed', execute_sync(record, at: NOW + 2)
    assert_equal [2, 2], [record.reload.completed_revision, record.attempts]
  ensure
    finish << true if finish
    worker&.join(5)
  end

  def test_durable_sync_crash_after_business_commit_replays_without_new_grants
    prepare_inbox_release
    record = accept_sync
    before = Toybaco::GrowthAiGrant.where(account_id: @account.id).order(:id).map(&:attributes)
    executor = Reconciliation::Execution.new(record, client: @release_provider, now: NOW, environment: { 'TOYBACO_STRIPE_MODE' => 'test' })
    finish = executor.method(:finish!)
    lost = false
    executor.define_singleton_method(:finish!) do |state, result|
      if state == 'completed' && !lost
        lost = true
        raise 'fixture completion acknowledgement lost'
      end
      finish.call(state, result)
    end
    travel_to(NOW) { assert_equal 'pending', executor.call }
    assert_equal 'processing_unavailable', record.reload.result
    assert_equal 'completed', execute_sync(record, at: NOW + 30)
    assert_equal before, Toybaco::GrowthAiGrant.where(account_id: @account.id).order(:id).map(&:attributes)
    assert_equal 'sub_repurchase', @account.reload.internal_attributes['toybaco_subscription_id']
  end

  def test_durable_sync_enqueue_failure_and_lost_reply_survive_sweep_without_duplicate_effects
    prepare_inbox_release
    accepted = []
    Toybaco::SubscriptionReconciliationJob.stub(:perform_later, ->(id) { accepted << id; raise ActiveJob::EnqueueError }) do
      record = Reconciliation.request!('sub_repurchase', mode: 'test', now: NOW)
      (@sync_receipts ||= []) << record.id
      assert_equal ['pending', 0], [record.state, record.attempts]
      assert_equal record.id, accepted.first
      assert_equal record.id, Reconciliation.request!('sub_repurchase', mode: 'test', now: NOW + 30).id
      assert_equal 1, accepted.size
    end
    record = SyncRequest.find(accepted.first)
    Toybaco::SubscriptionReconciliationJob.stub(:perform_later, ->(id) { accepted << id; true }) do
      travel_to(NOW + 60) { Toybaco::SubscriptionReconciliationSweepJob.perform_now }
    end
    assert_equal [record.id, record.id], accepted
    assert_equal 'completed', execute_sync(record, at: NOW + 60)
    assert_equal 'completed', execute_sync(record, at: NOW + 61)
    assert_equal 1, record.reload.attempts
  end

  def test_durable_sync_duplicate_notifications_never_extend_pending_deadline_or_attention
    prepare_inbox_release
    record = accept_sync
    original = record.deadline_at
    record.update!(attempts: 47)
    bad = Object.new
    bad.define_singleton_method(:retrieve_subscription) { |_| raise IOError, 'fixture transport only' }
    assert_equal 'attention', execute_sync(record, client: bad)
    assert_equal 48, record.reload.attempts
    duplicate = accept_sync(at: NOW + 1.day)
    assert_equal original, duplicate.deadline_at
    assert_equal 1, duplicate.requested_revision
    assert_equal 'attention', duplicate.state
    assert_equal 'attention', execute_sync(record, at: NOW + 2.days, client: bad)
    assert_equal 48, record.reload.attempts
  end

  def test_durable_sync_deadline_blocks_even_when_attempt_budget_remains
    prepare_inbox_release
    record = accept_sync
    duplicate = accept_sync(at: NOW + 23.hours)
    assert_equal [2, NOW + Reconciliation::DEADLINE], [duplicate.requested_revision, duplicate.deadline_at]
    provider = Object.new
    provider.define_singleton_method(:retrieve_subscription) { |_| flunk 'expired request cannot query provider' }
    assert_equal 'attention', execute_sync(record, at: NOW + 1.day, client: provider)
    assert_equal [0, 'retry_limit'], [record.reload.attempts, record.result]
  end

  def test_durable_sync_old_subscription_after_repurchase_is_superseded_without_provider_read
    prepare_inbox_release
    record = accept_sync
    travel_to NOW do
      @account.update!(internal_attributes: @account.internal_attributes.merge('toybaco_subscription_id' => 'sub_newer'))
    end
    before = @account.reload.attributes
    provider = Object.new
    provider.define_singleton_method(:retrieve_subscription) { |_| flunk 'old subscription must not be fetched' }
    assert_equal 'superseded', execute_sync(record, client: provider)
    assert_equal 1, record.reload.completed_revision
    assert_equal before, @account.reload.attributes
  end

  def test_durable_sync_waits_for_provisioning_and_binds_only_one_account
    record = accept_sync('sub_repurchase')
    assert_nil record.account_id
    assert_equal 'pending', execute_sync(record, client: Object.new)
    assert_equal 'not_provisioned', record.reload.result
    prepare_inbox_release
    assert_equal 'completed', execute_sync(record, at: NOW + 30)
    assert_equal @account.id, record.reload.account_id
  end

  def test_durable_sync_rejects_wrong_environment_and_wrong_provider_mode_without_business_changes
    prepare_inbox_release
    record = accept_sync
    before = @account.reload.attributes
    assert_equal 'attention', execute_sync(record, mode: 'live')
    assert_equal before, @account.reload.attributes
    record.update!(state: 'pending', next_attempt_at: NOW)
    @release_provider.sub['livemode'] = true
    assert_equal 'attention', execute_sync(record)
    assert_equal 'binding_unresolved', record.reload.result
    assert_equal before, @account.reload.attributes
  end

  def test_durable_sync_rejects_outer_transaction_and_nonfixed_reference
    count = SyncRequest.count
    assert_raises(Reconciliation::Invalid) { Account.transaction { accept_sync } }
    ['', 'sub_valid,other', 'sub_' + ('a' * 201), 'sub_a\n', 'evt_other'].each do |id|
      assert_raises(Reconciliation::Invalid) { accept_sync(id) }
    end
    assert_raises(Reconciliation::Invalid) { accept_sync(mode: 'sandbox') }
    assert_equal count, SyncRequest.count
    record = accept_sync
    assert_raises(Reconciliation::Invalid) do
      Account.transaction { Reconciliation::Execution.new(record, client: Object.new).call }
    end
    assert_equal 0, record.reload.attempts
  end

  def test_durable_sync_sweep_keeps_committed_work_when_acceptance_flag_is_off
    prepare_inbox_release
    record = accept_sync
    record.update!(next_enqueue_at: NOW)
    before = ENV['TOYBACO_SUBSCRIPTION_RECONCILIATION_ENABLED']
    ENV['TOYBACO_SUBSCRIPTION_RECONCILIATION_ENABLED'] = 'false'
    jobs = []
    Toybaco::SubscriptionReconciliationJob.stub(:perform_later, ->(id) { jobs << id; true }) do
      travel_to NOW do
        Toybaco::SubscriptionReconciliationSweepJob.perform_now
        Toybaco::SubscriptionReconciliationSweepJob.perform_now
      end
    end
    assert_equal [record.id], jobs
    assert_equal 'completed', execute_sync(record)
  ensure
    before ? ENV['TOYBACO_SUBSCRIPTION_RECONCILIATION_ENABLED'] = before : ENV.delete('TOYBACO_SUBSCRIPTION_RECONCILIATION_ENABLED')
  end

  def test_durable_sync_worker_claim_recovered_after_session_exit_and_job_payload_is_only_id
    prepare_inbox_release
    record = accept_sync
    record.update!(state: 'running', attempts: 1, next_attempt_at: NOW + 60)
    assert_equal 'running', execute_sync(record, at: NOW + 59)
    job = Toybaco::SubscriptionReconciliationJob.new(record.id).serialize
    assert_equal [record.id], job['arguments']
    assert_equal 'completed', execute_sync(record, at: NOW + 60)
    assert_equal 2, record.reload.attempts
  end
end

class ToybacoGrowthRenewalTransitionRuntimeTest
  def test_durable_sync_concurrent_first_notifications_share_one_receipt_without_losing_revision
    prepare_inbox_release
    ready, start = Queue.new, Queue.new
    workers = []
    Toybaco::SubscriptionReconciliationJob.stub(:perform_later, ->(*) { true }) do
      workers = 2.times.map do
        Thread.new do
          Account.connection_pool.with_connection do
            ready << true
            start.pop
            Reconciliation.request!('sub_repurchase', mode: 'test', now: NOW).id
          end
        end
      end
      2.times { Timeout.timeout(5) { ready.pop } }
      2.times { start << true }
      ids = workers.map { |worker| assert worker.join(5); worker.value }
      (@sync_receipts ||= []).concat(ids)
      assert_equal 1, ids.uniq.size
      record = SyncRequest.find(ids.first)
      assert_equal [2, 0, 0], record.attributes.values_at('requested_revision', 'completed_revision', 'attempts')
      assert_equal 'completed', execute_sync(record)
      assert_equal 2, record.reload.completed_revision
    end
  ensure
    workers&.each { |worker| start << true if worker.alive?; worker.join(5) }
  end

  def test_sync_rake_only_accepts_fixed_reference_when_opted_in_and_old_path_stays_available
    require 'rake'
    Rails.application.load_tasks unless Rake::Task.task_defined?('toybaco:sync_subscription')
    previous = ENV.to_h.slice('TOYBACO_SUBSCRIPTION_RECONCILIATION_ENABLED', 'TOYBACO_STRIPE_MODE')
    ENV['TOYBACO_SUBSCRIPTION_RECONCILIATION_ENABLED'] = 'true'
    ENV['TOYBACO_STRIPE_MODE'] = 'test'
    task = Rake::Task['toybaco:sync_subscription']
    args = Rake::TaskArguments.new([:subscription_id], ['sub_repurchase'])
    Toybaco::Checkout::Client.stub(:new, ->(*) { flunk 'acceptance cannot call Stripe' }) do
      Toybaco::SubscriptionReconciliationJob.stub(:perform_later, ->(*) { raise ActiveJob::EnqueueError }) do
        travel_to NOW do
          output, = capture_io { task.execute(args) }
          record = SyncRequest.find_by!(mode: 'test', subscription_id: 'sub_repurchase')
          (@sync_receipts ||= []) << record.id
          assert_includes output, "receipt=#{record.id} state=pending"
          assert_nil record.account_id
        end
      end
    end
    ENV['TOYBACO_SUBSCRIPTION_RECONCILIATION_ENABLED'] = 'false'
    output, = capture_io { task.execute(Rake::TaskArguments.new([:subscription_id], ['sub_notcreated'])) }
    assert_includes output, 'status=DEFERRED reason=not_provisioned'
    refute SyncRequest.exists?(subscription_id: 'sub_notcreated')
  ensure
    %w[TOYBACO_SUBSCRIPTION_RECONCILIATION_ENABLED TOYBACO_STRIPE_MODE].each do |key|
      previous&.key?(key) ? ENV[key] = previous[key] : ENV.delete(key)
    end
  end
end

class ToybacoGrowthRenewalTransitionRuntimeTest
  UpgradeContinuation = Toybaco::Growth::InboxUpgradeContinuation

  def paid_upgrade_subscription(plan: 'pro', at: NOW)
    sub = @release_provider.sub.deep_dup
    terms = Toybaco::PlanCatalog.default.definition(plan, '2026-09-18.1')
    price = repurchase_price.merge('id' => "price_upgrade#{plan}", 'unit_amount' => terms.dig('cycles', 'month', 'amount'),
      'metadata' => { 'toybaco_plan' => plan, 'toybaco_plan_version' => '2026-09-18.1' })
    sub['items']['data'].first['price'] = price
    invoice = sub['latest_invoice']
    invoice.merge!('id' => "in_upgrade#{plan}", 'billing_reason' => 'subscription_update')
    invoice['status_transitions']['paid_at'] = at.to_i
    invoice['lines']['data'].first.merge!('price' => { 'id' => price['id'] }, 'proration' => true)
    sub
  end

  def run_upgrade(sub = paid_upgrade_subscription, at: NOW)
    # Real Stripe responses are parsed JSON, never ActiveSupport::Duration.
    client = Struct.new(:sub) { def retrieve_subscription(*) = sub.deep_dup }.new(JSON.parse(JSON.generate(sub)))
    travel_to(at) { Toybaco::SubscriptionSync.new(client: client).call(@account, subscription_id: 'sub_repurchase') }
  end

  def current_release(at: NOW)
    attrs = @account.reload.internal_attributes
    id = attrs.dig(ReleaseRecord::KEY, 'request_id')
    if id
      value = Toybaco::GrowthInboxRelease.find_by!(account_id: @account.id, request_id: id).receipt
      assert ReleaseRecord.valid?(value, @account.id, now: at),
        "saved release invalid: confirmed=#{value['confirmed_at']} now=#{at.to_i} version=#{value['version']}"
    end
    ReleaseRecord.current(@account.id, attrs, attrs[InboxHold::KEY], now: at)
  end

  def test_paid_upgrade_continues_only_existing_explicit_inboxes_and_preserves_delivery_epoch
    prepare_inbox_release
    first = release_inbox
    third = create(:inbox, account: @account)
    before = @account.reload.internal_attributes.deep_dup
    tokens = @inboxes.map { |box| box.channel.reload.attributes }
    message = pending_reply(at: NOW + 1.second)
    queued = travel_to(NOW + 1.second) { serialized_dispatch(SendReplyJob.new(message.id)) }
    assert_equal 'applied', run_upgrade(paid_upgrade_subscription(at: NOW + 2.seconds), at: NOW + 2.seconds)
    value = current_release(at: NOW + 2.seconds)
    assert_equal 2, value['version']
    assert_equal 'paid_upgrade', value['operation']
    assert_empty value['requested_ids']
    assert_equal first['receipt_hash'], value['source_receipt_hash']
    assert_equal first['request_id'], value['previous_id']
    assert_equal first['keep_inbox_ids'], value['keep_inbox_ids']
    assert_equal 'pro', value.dig('binding', 'contract', 'plan_id')
    assert_equal before[DeliveryEpoch::KEY], @account.internal_attributes[DeliveryEpoch::KEY]
    assert_equal before[InboxHold::KEY], @account.internal_attributes[InboxHold::KEY]
    assert_equal before[Toybaco::Growth::PostingRetention::KEY], @account.internal_attributes[Toybaco::Growth::PostingRetention::KEY]
    assert_equal tokens, @inboxes.map { |box| box.channel.reload.attributes }
    assert_raises(InboxHold::Held) { InboxHold.with_inbox(third, now: NOW + 2.seconds) {} }
    assert_equal [:delivered], travel_to(NOW + 2.seconds) { perform_without_provider(queued) }
    assert_nil ActiveSupport::IsolatedExecutionState[UpgradeContinuation::CONTEXT]
  end

  def test_paid_upgrade_repeat_and_old_explicit_request_never_duplicate_or_restore_pointer
    prepare_inbox_release
    revision = release_service.read['revision']
    first = release_inbox(revision: revision)
    assert_equal 'applied', run_upgrade
    value = current_release
    grants = Toybaco::GrowthAiGrant.where(account_id: @account.id).order(:id).map(&:attributes)
    count = Toybaco::GrowthInboxRelease.where(account_id: @account.id).count
    assert_equal 'applied', run_upgrade
    assert_equal value, current_release
    assert_equal count, Toybaco::GrowthInboxRelease.where(account_id: @account.id).count
    assert_equal grants, Toybaco::GrowthAiGrant.where(account_id: @account.id).order(:id).map(&:attributes)
    assert_equal first, release_inbox(revision: revision)
    assert_equal value, current_release
    assert Toybaco::GrowthInboxRelease.find_by!(account_id: @account.id, request_id: value['request_id']).readonly?
  end

  def test_unpaid_upgrade_preserves_existing_choice_without_adding_new_rights_or_continuation
    prepare_inbox_release
    first = release_inbox
    before = @account.reload.internal_attributes.slice(*ContractBoundary::PROTECTED)
    sub = paid_upgrade_subscription
    sub['latest_invoice'].merge!('status' => 'open', 'amount_remaining' => 15000)
    assert_equal 'payment_pending', run_upgrade(sub)
    assert_equal 'standard', Toybaco::Entitlements.contract_for(@account.reload)['plan_id']
    assert_equal first, current_release
    assert_equal before, @account.internal_attributes.slice(*ContractBoundary::PROTECTED)
    assert_equal 1, Toybaco::GrowthInboxRelease.where(account_id: @account.id).count
  end

  def test_paid_upgrade_invalid_customer_mode_or_purchase_binding_rolls_back_without_releasing
    prepare_inbox_release
    release_inbox
    before = @account.reload.attributes
    variants = [paid_upgrade_subscription.merge('customer' => 'cus_foreign'), paid_upgrade_subscription.merge('livemode' => true)]
    wrong_nonce = paid_upgrade_subscription
    wrong_nonce['metadata']['toybaco_purchase_nonce'] = 'f' * 48
    variants << wrong_nonce
    variants.each do |sub|
      assert_raises(ReleaseRecord::Invalid) { run_upgrade(sub) }
      assert_equal before, @account.reload.attributes
      assert_equal 1, Toybaco::GrowthInboxRelease.where(account_id: @account.id).count
      assert_nil ActiveSupport::IsolatedExecutionState[UpgradeContinuation::CONTEXT]
    end
  end

  def test_paid_upgrade_sender_conflict_rolls_back_continuation_and_retries_after_sender_finishes
    prepare_inbox_release
    release_inbox
    before = @account.reload.internal_attributes.deep_dup
    with_other_inbox_sender do
      assert_raises(InboxHold::Busy) { Timeout.timeout(3) { run_upgrade } }
    end
    assert_equal before, @account.reload.internal_attributes
    assert_equal 1, Toybaco::GrowthInboxRelease.where(account_id: @account.id).count
    assert_nil ActiveSupport::IsolatedExecutionState[UpgradeContinuation::CONTEXT]
    assert_equal 'applied', run_upgrade
    assert_equal 2, current_release['version']
    assert_equal before[DeliveryEpoch::KEY], @account.internal_attributes[DeliveryEpoch::KEY]
  end

  def test_paid_upgrade_later_business_failure_rolls_back_choice_contract_and_grants
    prepare_inbox_release
    release_inbox
    before = @account.reload.internal_attributes.deep_dup
    grants = Toybaco::GrowthAiGrant.where(account_id: @account.id).order(:id).map(&:attributes)
    broken = Object.new
    broken.define_singleton_method(:observe!) { |_| raise 'fixture after contract application' }
    Toybaco::Growth::PaidPeriod.stub(:new, ->(*) { broken }) do
      assert_raises(RuntimeError) { run_upgrade }
    end
    assert_equal before, @account.reload.internal_attributes
    assert_equal grants, Toybaco::GrowthAiGrant.where(account_id: @account.id).order(:id).map(&:attributes)
    assert_equal 1, Toybaco::GrowthInboxRelease.where(account_id: @account.id).count
    assert_nil ActiveSupport::IsolatedExecutionState[UpgradeContinuation::CONTEXT]
    assert_equal 'applied', run_upgrade
    assert_equal 2, current_release['version']
  end

  def test_paid_upgrade_does_not_restore_choice_after_admin_stop_or_direct_contract_change
    prepare_inbox_release
    first = release_inbox
    old_contract = Toybaco::Entitlements.contract_for(@account).deep_dup
    travel_to NOW do
      @account.update!(status: 'suspended')
      @account.update!(status: 'active')
    end
    refute @account.reload.internal_attributes.key?(ReleaseRecord::KEY)
    assert_equal 'applied', run_upgrade
    refute @account.reload.internal_attributes.key?(ReleaseRecord::KEY)
    assert_raises(InboxHold::Held) { InboxHold.with_inbox(@inboxes.last, now: NOW) {} }
    travel_to NOW do
      Toybaco::Entitlements.apply!(@account, old_contract, subscription_id: 'sub_repurchase')
      assert_raises(InboxHold::Invalid) do
        @account.update!(internal_attributes: @account.reload.internal_attributes.merge(ReleaseRecord::KEY => ReleaseRecord.reference(first)))
      end
    end
  end

  def test_paid_upgrade_preserves_current_term_after_an_ordinary_paid_renewal
    prepare_inbox_release
    first = release_inbox
    sub = @release_provider.sub.deep_dup
    item = sub['items']['data'].first
    old_end = item['current_period_end']
    at = Time.at(old_end + 1.day.to_i).utc
    item.merge!('current_period_start' => old_end, 'current_period_end' => old_end + 30.days.to_i)
    invoice = sub['latest_invoice']
    invoice.merge!('id' => 'in_secondterm', 'billing_reason' => 'subscription_cycle')
    invoice['status_transitions']['paid_at'] = old_end
    invoice['lines']['data'].first['period'] = { 'start' => old_end, 'end' => old_end + 30.days.to_i }
    assert_equal 'applied', run_upgrade(sub, at: at)
    assert_equal first, current_release(at: at)
    @release_provider.sub = sub
    assert_equal 'applied', run_upgrade(paid_upgrade_subscription(at: at), at: at)
    value = current_release(at: at)
    assert_equal old_end, value.dig('source_coverage', 'term_start')
    assert_equal 'in_secondterm', value.dig('source_coverage', 'invoice_id')
    assert_equal first['keep_inbox_ids'], value['keep_inbox_ids']
    assert_equal :allowed, InboxHold.with_inbox(@inboxes.last, now: at) { :allowed }
  end

  def test_paid_upgrade_record_rejects_forged_choice_or_source_even_with_recomputed_hash
    prepare_inbox_release
    release_inbox
    third = create(:inbox, account: @account)
    run_upgrade
    value = current_release
    row = Toybaco::GrowthInboxRelease.where(account_id: @account.id, request_id: value['request_id'])
    variants = [value.merge('keep_inbox_ids' => (value['keep_inbox_ids'] + [third.id.to_s]).sort),
      value.merge('source_receipt_hash' => 'e' * 64), value.merge('previous_id' => value['request_id'])]
    variants.each do |variant|
      fields = variant.except('receipt_hash')
      variant['receipt_hash'] = Toybaco::Growth::RetentionSnapshot.fingerprint(fields)
      row.update_all(receipt: variant)
      assert_raises(ReleaseRecord::Invalid) { ReleaseRecord.find!(@account.id, value['request_id'], now: NOW) }
    end
  ensure
    row&.update_all(receipt: value) if value
  end

  def test_paid_upgrade_requires_same_verified_billing_owner_and_never_inherits_old_owner_choice
    prepare_inbox_release
    release_inbox
    replacement = create(:user, :administrator, account: @account)
    travel_to NOW do
      @account.update!(internal_attributes: @account.reload.internal_attributes.merge(Toybaco::BillingAccess::OWNER_KEY => replacement.id))
    end
    assert_equal 'applied', run_upgrade
    refute @account.reload.internal_attributes.key?(ReleaseRecord::KEY)
    assert_raises(InboxHold::Held) { InboxHold.with_inbox(@inboxes.last, now: NOW) {} }
    assert_equal 1, Toybaco::GrowthInboxRelease.where(account_id: @account.id).count
  ensure
    replacement&.destroy!
  end

  def test_two_paid_upgrades_keep_one_explicit_choice_and_validate_both_immutable_parents
    prepare_inbox_release
    light = paid_upgrade_subscription(plan: 'light')
    assert_equal 'applied', run_upgrade(light)
    @release_provider.sub = light
    first = release_inbox
    epoch = @account.reload.internal_attributes[DeliveryEpoch::KEY]
    standard = paid_upgrade_subscription(plan: 'standard')
    assert_equal 'applied', run_upgrade(standard)
    middle = current_release
    @release_provider.sub = standard
    assert_equal 'applied', run_upgrade
    value = current_release
    assert_equal first['request_id'], middle['previous_id']
    assert_equal middle['request_id'], value['previous_id']
    assert_equal first['keep_inbox_ids'], value['keep_inbox_ids']
    assert_equal epoch, @account.internal_attributes[DeliveryEpoch::KEY]
    assert_equal 3, Toybaco::GrowthInboxRelease.where(account_id: @account.id).count
    assert_equal :allowed, InboxHold.with_inbox(@inboxes.last, now: NOW) { :allowed }
  end

  def test_paid_cycle_change_is_not_an_upgrade_continuation
    prepare_inbox_release
    release_inbox
    sub = paid_upgrade_subscription
    price = sub['items']['data'].first['price']
    price['recurring']['interval'] = 'year'
    price['unit_amount'] = Toybaco::PlanCatalog.default.definition('pro', '2026-09-18.1').dig('cycles', 'year', 'amount')
    # A cycle change takes effect at the next paid term, rather than changing
    # the terms of an already issued grant under its original event key.
    starts_at = sub['items']['data'].first['current_period_end']
    ends_at = (Time.at(starts_at).utc + 1.year).to_i
    sub['billing_cycle_anchor'] = starts_at
    sub['items']['data'].first.merge!('current_period_start' => starts_at, 'current_period_end' => ends_at)
    sub['latest_invoice']['status_transitions']['paid_at'] = starts_at
    sub['latest_invoice']['lines']['data'].first['period'] = { 'start' => starts_at, 'end' => ends_at }
    at = Time.at(starts_at + 1).utc
    assert_equal 'applied', run_upgrade(sub, at: at)
    refute @account.reload.internal_attributes.key?(ReleaseRecord::KEY)
    assert_equal 1, Toybaco::GrowthInboxRelease.where(account_id: @account.id).count
    assert_raises(InboxHold::Held) { InboxHold.with_inbox(@inboxes.last, now: at) {} }
  end

  # posting-execution-tests-begin
  Execution = Toybaco::Growth::PostingExecution
  ExecutionContext = Toybaco::Growth::PostingExecutionContext
  ExecutionRow = Toybaco::GrowthPostingExecution

  def posting_execution_setup
    travel_to NOW
    @execution_prior_postiz = @account.reload.internal_attributes['postiz']&.deep_dup
    @account.with_lock do
      attrs = @account.internal_attributes.merge('postiz' => {
        'enabled' => true, 'organization_id' => Toybaco::PostizSync.deterministic_organization_id(@account.id) })
      # Fixture mapping only. Runtime mapping writer uses the same Account lock.
      @account.update_columns(internal_attributes: attrs)
    end
    @execution_request = { 'version' => 2, 'organization_id' => Toybaco::PostizSync.deterministic_organization_id(@account.id),
      'root_id' => 'execution-root', 'step_id' => 'execution-root', 'step' => 'MAIN', 'marker_hash' => 'b' * 64,
      'contract_hash' => ExecutionContext.contract_hash(@account.reload), 'authority_hash' => 'c' * 64,
      'principal' => Toybaco::Growth::PostingPrincipal.capture!(@account.id, actor_id: @owner.id, now: NOW) }
  end

  def posting_execution(operation: 'a' * 64, request: @execution_request, now: NOW, enabled: true)
    Execution.new(@account.id, operation_id: operation, request: request, now: now,
      environment: { 'TOYBACO_POSTING_EXECUTION_ENABLED' => enabled ? 'true' : 'false' })
  end

  def test_posting_execution_admission_is_closed_and_rejects_stale_or_foreign_contract
    posting_execution_setup
    assert_raises(ExecutionContext::Invalid) { posting_execution(enabled: false).prepare! }
    assert_raises(ExecutionContext::Invalid) { posting_execution(request: @execution_request.merge('unknown' => 'value')).prepare! }
    assert_raises(ExecutionContext::Invalid) { posting_execution(request: @execution_request.merge('organization_id' => 'other')).prepare! }
    assert_raises(ExecutionContext::Invalid) { posting_execution(request: @execution_request.merge('contract_hash' => 'd' * 64)).prepare! }
    assert_empty ExecutionRow.where(account_id: @account.id)
  end

  def test_posting_execution_start_response_loss_never_reissues_permission
    posting_execution_setup
    prepared = posting_execution.prepare!
    refute prepared['execute']
    assert posting_execution.start!['execute']
    assert_equal 'started', posting_execution.start!['state']
    refute posting_execution.start!['execute']
    assert_equal 'started', posting_execution.prepare!['state']
    refute posting_execution(now: NOW + 1.year).start!['execute']
    assert_equal 1, ExecutionRow.where(account_id: @account.id).count
  end

  def test_posting_execution_uncertain_is_not_expired_cancelled_or_retried
    posting_execution_setup
    posting_execution.prepare!
    posting_execution.start!
    assert_equal 'uncertain', posting_execution.mark_uncertain!['state']
    refute posting_execution(now: NOW + 1.year).start!['execute']
    assert_raises(ExecutionContext::Invalid) { posting_execution.cancel_prepared! }
    assert_raises(ExecutionContext::Invalid) { posting_execution.complete!(outcome: 'timeout', evidence_hash: 'e' * 64) }
    assert_raises(ExecutionContext::Busy) { @account.reload.update!(status: 'suspended') }
    assert_equal 'active', @account.reload.status
  end

  def test_posting_execution_blocks_all_bound_fields_but_preserves_grace_and_unrelated_edits
    posting_execution_setup
    posting_execution.prepare!
    before = @account.reload.internal_attributes.deep_dup
    changes = { 'toybaco_subscription_id' => 'sub_changed', 'toybaco_stripe_customer_id' => 'cus_changed',
      'toybaco_billing_owner_user_id' => 999, 'toybaco_contract' => before.fetch('toybaco_contract').merge('plan_id' => 'pro'),
      'toybaco_growth_purchase' => { 'nonce' => 'new', 'state' => 'complete' }, 'postiz' => { 'enabled' => false } }
    changes.each do |key, value|
      assert_raises(ExecutionContext::Busy) { @account.reload.update!(internal_attributes: before.merge(key => value)) }
      assert_equal before, @account.reload.internal_attributes
    end
    @account.update!(name: 'Unrelated name', internal_attributes: before.merge('toybaco_subscription_status' => 'past_due'))
    assert_equal 'Unrelated name', @account.reload.name
    assert_equal 'past_due', @account.internal_attributes['toybaco_subscription_status']
    assert posting_execution.start!['execute']
  end

  def test_posting_execution_keeps_fence_when_admission_disabled_and_completion_is_exact
    posting_execution_setup
    posting_execution.prepare!
    posting_execution.start!
    assert_raises(ExecutionContext::Invalid) { posting_execution(enabled: false).start! }
    assert_raises(ExecutionContext::Busy) { @account.reload.update!(status: 'suspended') }
    closed = posting_execution(enabled: false).complete!(outcome: 'published', evidence_hash: 'e' * 64)
    assert_equal 'completed', closed['state']
    assert_equal closed, posting_execution.complete!(outcome: 'published', evidence_hash: 'e' * 64)
    assert_raises(ExecutionContext::Invalid) { posting_execution.complete!(outcome: 'rejected', evidence_hash: 'e' * 64) }
    assert_raises(ExecutionContext::Invalid) { posting_execution.complete!(outcome: 'published', evidence_hash: 'f' * 64) }
    @account.reload.update!(internal_attributes: @account.internal_attributes.merge('toybaco_subscription_id' => 'sub_new'))
    refute posting_execution.start!['execute']
    assert_equal 'sub_new', @account.reload.internal_attributes['toybaco_subscription_id']
  end

  def test_posting_execution_prepared_cancellation_is_terminal_and_identity_is_not_rearmed
    posting_execution_setup
    posting_execution.prepare!
    closed = posting_execution(enabled: false).cancel_prepared!
    assert_equal closed, posting_execution.cancel_prepared!
    refute posting_execution.start!['execute']
    assert_raises(ExecutionContext::Invalid) { posting_execution(operation: 'd' * 64).prepare! }
    assert_raises(ExecutionContext::Invalid) { posting_execution(request: @execution_request.merge('authority_hash' => 'd' * 64)).prepare! }
    assert_equal 1, ExecutionRow.where(account_id: @account.id).count
  end

  def test_posting_execution_concurrent_start_grants_once_and_is_uncached
    posting_execution_setup
    posting_execution.prepare!
    ready, go, results = Queue.new, Queue.new, Queue.new
    workers = 2.times.map do
      Thread.new do
        Account.connection_pool.with_connection do
          ready << true
          go.pop
          result = begin
            Account.cache { posting_execution.start! }
          rescue ExecutionContext::Busy
            { 'execute' => false }
          end
          results << result
        end
      end
    end
    2.times { Timeout.timeout(5) { ready.pop } }
    2.times { go << true }
    workers.each { |worker| raise 'posting execution worker timeout' unless worker.join(5); worker.value }
    assert_equal 1, 2.times.map { results.pop }.count { |result| result['execute'] }
    refute Account.cache { posting_execution.start!['execute'] }
  ensure
    workers&.each { |worker| worker.kill.join if worker.alive? }
  end

  def test_posting_execution_account_lock_and_outer_transaction_fail_without_partial_admission
    posting_execution_setup
    ready, done = Queue.new, Queue.new
    worker = Thread.new do
      Account.connection_pool.with_connection do
        Account.transaction do
          Account.lock.find(@account.id)
          ready << true
          done.pop
        end
      end
    end
    Timeout.timeout(5) { ready.pop }
    assert_raises(ExecutionContext::Busy) { Timeout.timeout(2) { posting_execution.prepare! } }
    assert_empty ExecutionRow.where(account_id: @account.id)
    done << true
    worker.join(5)
    worker.value
    assert_raises(ExecutionContext::Invalid) { Account.transaction { posting_execution.prepare! } }
    assert_equal 'prepared', posting_execution.prepare!['state']
  ensure
    done << true if done
    worker.kill.join if worker&.alive?
  end

  def test_posting_execution_fence_rolls_back_contract_writer_before_external_lifecycle
    posting_execution_setup
    posting_execution.prepare!
    posting_execution.start!
    disabled = []
    before = @account.reload.attributes.deep_dup
    Toybaco::PostizSync.stub(:disable_account!, ->(**) { disabled << true }) do
      assert_raises(ExecutionContext::Busy) do
        @account.with_lock do
          @account.update!(name: 'must roll back')
          @account.update!(status: 'suspended')
        end
      end
    end
    assert_empty disabled
    assert_equal before, @account.reload.attributes
    assert_equal 'started', ExecutionRow.find_by!(account_id: @account.id).state
  end

  def test_posting_execution_rolls_back_start_failure_and_rejects_corrupted_request
    posting_execution_setup
    posting_execution.prepare!
    service = posting_execution
    service.stub(:receipt, ->(*) { raise 'simulated result failure' }) do
      assert_raises(RuntimeError) { service.start! }
    end
    assert_equal 'prepared', ExecutionRow.find_by!(account_id: @account.id).state
    assert posting_execution.start!['execute']
    ExecutionRow.where(account_id: @account.id).update_all(request_hash: 'f' * 64)
    assert_raises(ExecutionContext::Invalid) { posting_execution.complete!(outcome: 'published', evidence_hash: 'e' * 64) }
    assert_raises(ExecutionContext::Busy) { @account.reload.update!(status: 'suspended') }
  end

  def test_posting_execution_delete_is_fenced_and_terminal_minimal_evidence_is_retained
    posting_execution_setup
    posting_execution.prepare!
    assert_raises(ExecutionContext::Busy) { @account.destroy! }
    assert Account.exists?(@account.id)
    posting_execution.start!
    posting_execution.complete!(outcome: 'rejected', evidence_hash: 'e' * 64)
    stored = ExecutionRow.find_by!(account_id: @account.id).attributes.deep_dup
    Toybaco::PostizSync.stub(:disable_account!, ->(**) { :unconfigured }) { @account.destroy! }
    refute Account.exists?(@account.id)
    assert_equal stored, ExecutionRow.find_by!(account_id: @account.id).attributes
    assert_equal @execution_request.keys.sort, stored.fetch('request').keys.sort
  end

  def test_posting_execution_step_identity_separates_comments_and_finalization
    posting_execution_setup
    posting_execution.prepare!
    posting_execution.cancel_prepared!
    %w[COMMENT FINALIZE].each_with_index do |step, index|
      request = @execution_request.merge('step' => step, 'step_id' => "step-#{index}")
      operation = (index + 1).to_s * 64
      service = posting_execution(request: request, operation: operation)
      assert_equal 'prepared', service.prepare!['state']
      assert service.start!['execute']
      assert_equal 'completed', service.complete!(outcome: 'published', evidence_hash: 'e' * 64)['state']
      refute service.start!['execute']
    end
    assert_equal 3, ExecutionRow.where(account_id: @account.id).count
  end
  def test_posting_execution_repeatable_read_writer_cannot_ignore_later_start
    posting_execution_setup
    worker = nil
    disabled = []
    Toybaco::PostizSync.stub(:disable_account!, ->(**) { disabled << true }) do
      Account.transaction(isolation: :repeatable_read) do
        @account.reload
        assert_empty ExecutionRow.where(account_id: @account.id)
        worker = Thread.new do
          Account.connection_pool.with_connection do
            posting_execution.prepare!
            posting_execution.start!
          end
        end
        raise 'execution admission timeout' unless worker.join(5)
        assert worker.value['execute']
        # The record is committed on the other connection but absent in this snapshot.
        assert_empty ExecutionRow.where(account_id: @account.id)
        assert_raises(ExecutionContext::Invalid) { @account.update!(status: 'suspended') }
      end
    end
    assert_empty disabled
    assert_equal 'active', @account.reload.status
    assert_equal 'started', ExecutionRow.find_by!(account_id: @account.id).state
  ensure
    worker.kill.join if worker&.alive?
  end

  def test_posting_execution_serializable_contract_writer_is_rejected_before_side_effects
    posting_execution_setup
    disabled = []
    Toybaco::PostizSync.stub(:disable_account!, ->(**) { disabled << true }) do
      Account.transaction(isolation: :serializable) do
        @account.reload
        assert_raises(ExecutionContext::Invalid) { @account.update!(status: 'suspended') }
      end
    end
    assert_empty disabled
    assert_equal 'active', @account.reload.status
  end
  # posting-execution-tests-end
  def test_posting_execution_real_subscription_sync_defers_until_definitive_completion
    posting_execution_setup
    posting_execution.prepare!
    posting_execution.start!
    @provider.sub['items']['data'].first['price'].merge!('unit_amount' => 19800, 'currency' => 'jpy', 'recurring' => { 'interval' => 'month' })
    @provider.sub['status'] = 'canceled'
    before = @account.reload.internal_attributes.deep_dup
    disabled = []
    Toybaco::PostizSync.stub(:disable_account!, ->(**) { disabled << true; :unconfigured }) do
      assert_raises(ExecutionContext::Busy) do
        travel_to(NOW) { Toybaco::SubscriptionSync.new(client: @provider).call(@account, subscription_id: 'sub_transition') }
      end
      assert_empty disabled
      assert_equal before, @account.reload.internal_attributes
      assert_equal 'active', @account.status
      posting_execution.complete!(outcome: 'rejected', evidence_hash: 'e' * 64)
      travel_to NOW do
        assert_equal 'applied', Toybaco::SubscriptionSync.new(client: @provider).call(@account.reload, subscription_id: 'sub_transition')
      end
      assert_equal 'suspended', @account.reload.status
    end
  end

  # posting-stop-tests-begin
  PostingStop = Toybaco::Growth::PostingStop
  PostingStopContext = Toybaco::Growth::PostingStopContext
  PostingStopRow = Toybaco::GrowthPostingStop

  def posting_stop_setup
    travel_to NOW
    posting_execution_setup
    @stop_contract_hash = ExecutionContext.contract_hash(@account.reload)
    @stop_target_hash = ExecutionContext.digest(ExecutionContext.binding('suspended', @account.internal_attributes))
  end

  def posting_stop(operation: 'd' * 64, contract_hash: @stop_contract_hash, target_hash: @stop_target_hash, now: NOW, enabled: true)
    PostingStop.new(@account.id, operation_id: operation, request: { 'contract_hash' => contract_hash, 'target_hash' => target_hash },
      environment: { 'TOYBACO_POSTING_STOP_ENABLED' => enabled ? 'true' : 'false' }, now: now)
  end

  def apply_posting_stop
    Toybaco::PostizSync.stub(:disable_account!, ->(**) { :unconfigured }) { @account.reload.update!(status: 'suspended') }
  end

  def test_posting_stop_flag_binding_and_outer_transaction_reject_before_mutation
    posting_stop_setup
    assert_raises(PostingStopContext::Invalid) { posting_stop(enabled: false).request! }
    assert_raises(PostingStopContext::Invalid) { posting_stop(contract_hash: 'e' * 64).request! }
    assert_raises(PostingStopContext::Invalid) { posting_stop(target_hash: @stop_contract_hash).request! }
    assert_raises(PostingStopContext::Invalid) { Account.transaction { posting_stop.request! } }
    assert_empty PostingStopRow.where(account_id: @account.id)
  end

  def test_posting_stop_cancels_only_unstarted_and_closes_new_admission
    posting_stop_setup
    posting_execution.prepare!
    receipt = posting_stop.request!
    assert_equal 'pending', receipt['state']
    assert_equal 'cancelled', posting_execution.start!['state']
    refute posting_execution.start!['execute']
    assert_equal 'cancelled', ExecutionRow.find_by!(account_id: @account.id).state
    assert_raises(PostingStopContext::Busy) { posting_execution(operation: 'f' * 64).prepare! }
    assert_equal receipt, posting_stop.request!
    assert_equal 1, PostingStopRow.where(account_id: @account.id).count
  end

  def test_posting_stop_preserves_uncertain_call_and_does_not_expire_or_starve
    posting_stop_setup
    posting_execution.prepare!
    posting_execution.start!
    posting_execution.mark_uncertain!
    posting_stop.request!
    6.times do |n|
      assert_raises(PostingStopContext::Busy) { posting_execution(operation: n.to_s.rjust(64, '0')).prepare! }
    end
    assert_raises(ExecutionContext::Busy) { apply_posting_stop }
    assert_equal 'uncertain', ExecutionRow.find_by!(account_id: @account.id).state
    assert_equal 'pending', posting_stop(now: NOW + 1.year).request!['state']
    assert_raises(ExecutionContext::Busy) { apply_posting_stop }
    posting_execution.complete!(outcome: 'rejected', evidence_hash: 'e' * 64)
    apply_posting_stop
    assert_equal 'applied', posting_stop.request!['state']
    assert_equal 'suspended', @account.reload.status
  end

  def test_posting_stop_replay_cannot_change_target_or_replace_pending_request
    posting_stop_setup
    first = posting_stop.request!
    assert_equal first, posting_stop.request!
    assert_raises(PostingStopContext::Invalid) { posting_stop(target_hash: 'e' * 64).request! }
    assert_raises(PostingStopContext::Busy) { posting_stop(operation: 'f' * 64).request! }
    assert_equal first, posting_stop.request!
  end

  def test_posting_stop_request_rolls_back_prepared_cancellation_on_failure
    posting_stop_setup
    posting_execution.prepare!
    service = posting_stop
    service.stub(:receipt, ->(*) { raise 'receipt interrupted' }) do
      assert_raises(RuntimeError) { service.request! }
    end
    assert_empty PostingStopRow.where(account_id: @account.id)
    assert_equal 'prepared', ExecutionRow.find_by!(account_id: @account.id).state
    assert posting_execution.start!['execute']
  end

  def test_posting_stop_target_and_terminal_receipt_share_writer_transaction
    posting_stop_setup
    posting_stop.request!
    assert_raises(RuntimeError) do
      Account.transaction do
        apply_posting_stop
        assert_equal 'applied', PostingStopRow.find_by!(account_id: @account.id).state
        raise 'later business update failed'
      end
    end
    assert_equal 'active', @account.reload.status
    assert_equal 'pending', PostingStopRow.find_by!(account_id: @account.id).state
    apply_posting_stop
    assert_equal 'applied', posting_stop.request!['state']
    @account.reload.update!(status: 'active')
    assert_equal 'applied', posting_stop.request!['state']
    assert_equal 'active', @account.reload.status
  end

  def test_posting_stop_allows_grace_and_name_but_rejects_different_target_and_delete
    posting_stop_setup
    posting_stop.request!
    @account.reload.update!(name: 'Unrelated edit', internal_attributes: @account.internal_attributes.merge('toybaco_billing_state' => 'past_due'))
    assert_equal 'pending', PostingStopRow.find_by!(account_id: @account.id).state
    assert_raises(PostingStopContext::Busy) do
      @account.update!(internal_attributes: @account.internal_attributes.merge('toybaco_stripe_customer_id' => 'cus_other'))
    end
    assert_raises(PostingStopContext::Busy) { @account.reload.destroy! }
    assert_equal @stop_contract_hash, ExecutionContext.contract_hash(@account.reload)
  end

  def test_posting_stop_withdrawal_keeps_cancelled_jobs_and_old_replay_does_not_reclose
    posting_stop_setup
    posting_execution.prepare!
    posting_stop.request!
    old = posting_stop(enabled: false).withdraw!
    assert_equal 'withdrawn', old['state']
    assert_equal 'cancelled', posting_execution.start!['state']
    assert_equal old, posting_stop.request!
    request = @execution_request.merge('root_id' => 'new-root', 'step_id' => 'new-root')
    assert_equal 'prepared', posting_execution(operation: 'f' * 64, request: request).prepare!['state']
    newer = posting_stop(operation: 'e' * 64).request!
    assert_equal old, posting_stop.withdraw!
    assert_equal newer, posting_stop(operation: 'e' * 64).request!
    assert_raises(PostingStopContext::Busy) { posting_execution(operation: '0' * 64, request: request).prepare! }
  end

  def test_posting_stop_separate_connection_blocks_start_until_stop_commits
    posting_stop_setup
    posting_execution.prepare!
    locked, release = Queue.new, Queue.new
    original = PostingStopRow.method(:create!)
    worker = nil
    PostingStopRow.stub(:create!, ->(*args) { locked << true; release.pop; original.call(*args) }) do
      worker = Thread.new { Account.connection_pool.with_connection { posting_stop.request! } }
      Timeout.timeout(5) { locked.pop }
      assert_raises(ExecutionContext::Busy) { Timeout.timeout(2) { posting_execution.start! } }
      release << true
      raise 'stop worker timeout' unless worker.join(5)
      assert_equal 'pending', worker.value['state']
    end
    assert_equal 'cancelled', posting_execution.start!['state']
    refute posting_execution.start!['execute']
  ensure
    release << true if release
    worker.kill.join if worker&.alive?
  end

  def test_posting_stop_admission_ignores_cached_absence_after_another_session_commits
    posting_stop_setup
    worker = nil
    Account.cache do
      assert_nil PostingStopContext.pending(@account.id)
      worker = Thread.new { Account.connection_pool.with_connection { posting_stop.request! } }
      raise 'stop worker timeout' unless worker.join(5)
      assert_equal 'pending', worker.value['state']
      assert_raises(PostingStopContext::Busy) { posting_execution.prepare! }
    end
    assert_empty ExecutionRow.where(account_id: @account.id)
  ensure
    worker.kill.join if worker&.alive?
  end

  def test_posting_stop_corruption_is_not_an_admission_or_writer_bypass
    posting_stop_setup
    posting_stop.request!
    PostingStopRow.where(account_id: @account.id).update_all(request_hash: '0' * 64)
    assert_raises(PostingStopContext::Invalid) { posting_execution.prepare! }
    assert_raises(PostingStopContext::Invalid) { apply_posting_stop }
    assert_raises(PostingStopContext::Invalid) { posting_stop.withdraw! }
    assert_equal 'active', @account.reload.status
  end

  def test_posting_stop_database_rejects_terminal_without_time_and_duplicate_pending
    posting_stop_setup
    posting_stop.request!
    row = PostingStopRow.find_by!(account_id: @account.id)
    assert_raises(ActiveRecord::StatementInvalid) do
      PostingStopRow.transaction(requires_new: true) { PostingStopRow.where(id: row.id).update_all(state: 'withdrawn') }
    end
    assert_equal 'pending', row.reload.state
    assert_raises(ActiveRecord::RecordNotUnique) do
      PostingStopRow.transaction(requires_new: true) { PostingStopRow.create!(row.attributes.except('id').merge('operation_id' => 'e' * 64)) }
    end
    assert_equal 1, PostingStopRow.where(account_id: @account.id).count
  end
  # posting-stop-tests-end
  def test_posting_stop_real_subscription_sync_resolves_only_after_definitive_completion
    posting_stop_setup
    target_attrs = @account.internal_attributes.merge('postiz' => @account.internal_attributes.fetch('postiz').merge('enabled' => false))
    @stop_target_hash = ExecutionContext.digest(ExecutionContext.binding('suspended', target_attrs))
    posting_execution.prepare!
    posting_execution.start!
    posting_stop.request!
    @provider.sub['items']['data'].first['price'].merge!('unit_amount' => 19800, 'currency' => 'jpy', 'recurring' => { 'interval' => 'month' })
    @provider.sub['status'] = 'canceled'
    disabled = []
    Toybaco::PostizSync.stub(:disable_account!, ->(**) { disabled << true; :unconfigured }) do
      assert_raises(ExecutionContext::Busy) { Toybaco::SubscriptionSync.new(client: @provider).call(@account.reload, subscription_id: 'sub_transition') }
      assert_empty disabled
      assert_equal 'pending', posting_stop.request!['state']
      assert_raises(PostingStopContext::Busy) { posting_execution(operation: 'f' * 64).prepare! }
      posting_execution.complete!(outcome: 'rejected', evidence_hash: 'e' * 64)
      assert_equal 'applied', Toybaco::SubscriptionSync.new(client: @provider).call(@account.reload, subscription_id: 'sub_transition')
      assert_equal 'applied', posting_stop.request!['state']
      assert_equal 'suspended', @account.reload.status
      terminal = PostingStopRow.find_by!(account_id: @account.id).attributes.deep_dup
      assert_equal 'applied', Toybaco::SubscriptionSync.new(client: @provider).call(@account.reload, subscription_id: 'sub_transition')
      assert_equal terminal, PostingStopRow.find_by!(account_id: @account.id).attributes
    end
  end

end

class ToybacoGrowthRenewalTransitionRuntimeTest
  # posting-membership-tests-begin
  MembershipBoundary = Toybaco::Growth::PostingMembershipBoundary

  def membership_setup
    travel_to NOW
    @membership = AccountUser.find_by!(user_id: @owner.id, account_id: @account.id)
    posting_execution_setup
  end

  def membership_provider
    @membership_calls = []
    Toybaco::PostizSync.stub(:demote_membership!, ->(**) { @membership_calls << :demote; :demoted }) do
      Toybaco::PostizSync.stub(:revoke_membership!, ->(**) { @membership_calls << :revoke; :revoked }) do
        Toybaco::PostizSync.stub(:disable_user!, ->(**) { @membership_calls << :disable; :disabled }) do
          Toybaco::PostizSync.stub(:sync!, ->(**) { @membership_calls << :sync; {} }) { yield }
        end
      end
    end
  end

  def test_membership_demotion_and_removal_wait_for_definitive_execution
    membership_setup
    posting_execution.prepare!
    posting_execution.start!
    membership_provider do
      assert_raises(ExecutionContext::Busy) { @membership.update!(role: :agent) }
      assert_raises(ExecutionContext::Busy) { @membership.reload.destroy! }
      assert_empty @membership_calls
      assert @membership.reload.administrator?
      posting_execution.mark_uncertain!
      assert_raises(ExecutionContext::Busy) { @membership.update!(role: :agent) }
      posting_execution.complete!(outcome: 'rejected', evidence_hash: 'e' * 64)
      @membership.reload.update!(role: :agent)
      assert @membership.reload.agent?
      assert_includes @membership_calls, :demote
    end
  end

  def test_membership_prepared_execution_blocks_user_identity_and_destroy
    membership_setup
    # Email-provider uid is canonicalized back to email by DeviseTokenAuth before_save.
    @owner.update!(provider: 'google_oauth2')
    @execution_request['principal'] = Toybaco::Growth::PostingPrincipal.capture!(@account.id, actor_id: @owner.id, now: NOW)
    posting_execution.prepare!
    identity = @owner.attributes.slice('uid', 'provider', 'type')
    membership_provider do
      [{ uid: 'changed-user' }, { provider: 'changed-provider' }, { type: 'SuperAdmin' }].each do |changes|
        assert_raises(ExecutionContext::Busy) { @owner.reload.update!(changes) }
        assert_equal identity, @owner.reload.attributes.slice('uid', 'provider', 'type')
      end
      assert_raises(ExecutionContext::Busy) { @owner.destroy! }
      assert_empty @membership_calls
      assert User.exists?(@owner.id)
    end
  end

  def test_membership_unrelated_presence_and_user_settings_remain_editable
    membership_setup
    posting_execution.prepare!
    membership_provider do
      @membership.update!(auto_offline: false)
      @owner.update!(ui_settings: { 'fixture' => 'unchanged-authority' })
      assert_equal false, @membership.reload.auto_offline
      assert_equal 'unchanged-authority', @owner.reload.ui_settings['fixture']
      assert_empty @membership_calls
      assert posting_execution.start!['execute']
    end
  end

  def test_membership_move_checks_old_account_and_rejects_stale_authority
    membership_setup
    other = create(:user)
    posting_execution.prepare!
    membership_provider do
      assert_raises(ExecutionContext::Busy) { @membership.update!(user_id: other.id) }
      assert_equal @owner.id, @membership.reload.user_id
      posting_execution.cancel_prepared!
      stale = AccountUser.find(@membership.id)
      @membership.update!(role: :agent)
      assert_raises(ExecutionContext::Invalid) { stale.update!(role: :agent) }
      assert @membership.reload.agent?
    end
  ensure
    other&.destroy!
  end

  def test_membership_pending_stop_blocks_new_members_and_old_withdraw_does_not_restore_jobs
    membership_setup
    @stop_contract_hash = ExecutionContext.contract_hash(@account.reload)
    @stop_target_hash = ExecutionContext.digest(ExecutionContext.binding('suspended', @account.internal_attributes))
    other = create(:user)
    posting_execution.prepare!
    posting_stop.request!
    membership_provider do
      assert_raises(PostingStopContext::Busy) { AccountUser.create!(account: @account, user: other, role: :agent) }
      assert_raises(PostingStopContext::Busy) { @membership.update!(role: :agent) }
      assert_raises(PostingStopContext::Busy) { @owner.destroy! }
      assert_empty @membership_calls
      posting_stop.withdraw!
      @membership.reload.update!(role: :agent)
      assert @membership.reload.agent?
      assert_equal 'cancelled', posting_execution.start!['state']
    end
  ensure
    other&.destroy!
  end

  def test_membership_query_cache_cannot_hide_execution_committed_on_other_connection
    worker = nil
    membership_setup
    Account.cache do
      refute ExecutionRow.where(account_id: @account.id).where.not(state: %w[completed cancelled]).exists?
      worker = Thread.new { Account.connection_pool.with_connection { posting_execution.prepare! } }
      raise 'membership prepare timeout' unless worker.join(5)
      worker.value
      membership_provider { assert_raises(ExecutionContext::Busy) { @membership.update!(role: :agent) } }
      assert @membership.reload.administrator?
    end
  ensure
    worker.kill.join if worker&.alive?
  end

  def test_membership_writer_blocks_new_execution_before_external_demotion
    worker = nil
    membership_setup
    ready, done = Queue.new, Queue.new
    Toybaco::PostizSync.stub(:demote_membership!, ->(**) { ready << true; done.pop; :demoted }) do
      Toybaco::PostizSync.stub(:sync!, ->(**) { {} }) do
        worker = Thread.new do
          Account.connection_pool.with_connection { AccountUser.find(@membership.id).update!(role: :agent) }
        end
        Timeout.timeout(5) { ready.pop }
        assert_raises(ExecutionContext::Busy) { Timeout.timeout(2) { posting_execution.prepare! } }
        assert_empty ExecutionRow.where(account_id: @account.id)
        done << true
        raise 'membership writer timeout' unless worker.join(5)
        worker.value
      end
    end
    assert @membership.reload.agent?
    assert_raises(ExecutionContext::Invalid) { posting_execution.prepare! }
  ensure
    done << true if done
    worker.kill.join if worker&.alive?
  end

  def test_membership_savepoint_retains_fence_until_outer_rollback
    worker = nil
    membership_setup
    membership_provider do
      Account.transaction do
        Account.transaction(requires_new: true) { @membership.update!(role: :agent) }
        result = nil
        worker = Thread.new do
          Account.connection_pool.with_connection do
            result = begin
              posting_execution.prepare!
            rescue ExecutionContext::Busy
              :busy
            end
          end
        end
        raise 'membership outer transaction timeout' unless worker.join(5)
        worker.value
        assert_equal :busy, result
        raise ActiveRecord::Rollback
      end
      assert @membership.reload.administrator?
      assert_equal 'prepared', posting_execution.prepare!['state']
    end
  ensure
    worker.kill.join if worker&.alive?
  end

  def test_membership_snapshot_isolation_is_rejected_before_external_mutation
    membership_setup
    membership_provider do
      %i[repeatable_read serializable].each do |isolation|
        assert_raises(ExecutionContext::Invalid) do
          Account.transaction(isolation: isolation) { @membership.reload.update!(role: :agent) }
        end
        assert @membership.reload.administrator?
      end
      assert_empty @membership_calls
    end
  end

  def test_membership_sync_uses_real_identity_guard_before_every_postiz_writer
    membership_setup
    posting_execution.prepare!
    calls = []
    Toybaco::PostizSync.stub(:configured?, true) do
      Toybaco::PostizSync.stub(:with_transaction, ->(*) { calls << :external; raise 'external mutation must not run' }) do
        operations = [-> { Toybaco::PostizSync.sync!(user: @owner, account: @account) },
                      -> { Toybaco::PostizSync.demote_membership!(user_id: @owner.id, account: @account) },
                      -> { Toybaco::PostizSync.revoke_membership!(user_id: @owner.id, account: @account) },
                      -> { Toybaco::PostizSync.disable_account!(account: @account) },
                      -> { Toybaco::PostizSync.disable_user!(user_id: @owner.id) }]
        operations.each { |operation| assert_raises(ExecutionContext::Busy, &operation) }
      end
    end
    assert_empty calls
  end

  def test_membership_sync_account_lock_lasts_through_external_transaction
    worker = nil
    membership_setup
    # Email-provider uid is canonicalized back to email by DeviseTokenAuth before_save.
    @owner.update!(provider: 'google_oauth2')
    @execution_request['principal'] = Toybaco::Growth::PostingPrincipal.capture!(@account.id, actor_id: @owner.id, now: NOW)
    ready, done = Queue.new, Queue.new
    Toybaco::PostizSync.stub(:configured?, true) do
      Toybaco::PostizSync.stub(:sync_under_identity_lock, ->(*) { ready << true; done.pop; :synchronized }) do
        worker = Thread.new do
          Account.connection_pool.with_connection { Toybaco::PostizSync.sync!(user: @owner, account: @account) }
        end
        Timeout.timeout(5) { ready.pop }
        assert_raises(ExecutionContext::Busy) { Timeout.timeout(2) { posting_execution.prepare! } }
        assert_raises(ExecutionContext::Busy) { Timeout.timeout(2) { @owner.update!(uid: 'new-owner') } }
        done << true
        raise 'membership sync timeout' unless worker.join(5)
        assert_equal :synchronized, worker.value
      end
    end
    assert_equal 'prepared', posting_execution.prepare!['state']
  ensure
    done << true if done
    worker.kill.join if worker&.alive?
  end

  def test_membership_failure_rolls_back_before_external_revoke_and_keeps_history
    membership_setup
    membership_provider do
      original = @membership.attributes.deep_dup
      AccountUser.transaction do
        @membership.destroy!
        assert_equal [:revoke], @membership_calls
        raise ActiveRecord::Rollback
      end
      assert_equal original.slice('account_id', 'user_id', 'role'), @membership.reload.attributes.slice('account_id', 'user_id', 'role')
      assert_equal 'prepared', posting_execution.prepare!['state']
    end
  end
  def test_membership_user_identity_checks_every_account_and_keeps_unrelated_membership
    membership_setup
    # Email-provider uid is canonicalized back to email by DeviseTokenAuth before_save.
    @owner.update!(provider: 'google_oauth2')
    @execution_request['principal'] = Toybaco::Growth::PostingPrincipal.capture!(@account.id, actor_id: @owner.id, now: NOW)
    other_account = Account.create!(name: 'Membership fixture')
    other_membership = AccountUser.create!(account: other_account, user: @owner, role: :agent)
    posting_execution.prepare!
    membership_provider do
      assert_raises(ExecutionContext::Busy) { @owner.update!(uid: 'changed-everywhere') }
      assert_raises(ExecutionContext::Busy) { @owner.reload.destroy! }
      assert_equal 2, AccountUser.where(user_id: @owner.id).count
      other_membership.destroy!
      assert_equal 1, AccountUser.where(user_id: @owner.id).count
      assert_equal [:revoke], @membership_calls
      assert posting_execution.start!['execute']
    end
  ensure
    other_account&.destroy!
  end

  def test_membership_email_uid_normalization_does_not_change_authority
    membership_setup
    identity = @owner.reload.attributes.slice('uid', 'provider', 'email')
    assert_equal 'email', identity['provider']
    assert_equal identity['email'], identity['uid']
    posting_execution.prepare!
    membership_provider do
      @owner.update!(uid: 'ignored-by-email-provider')
      assert_equal identity, @owner.reload.attributes.slice('uid', 'provider', 'email')
      assert_empty @membership_calls
      assert posting_execution.start!['execute']
    end
  end

  # posting-membership-tests-end

end

class ToybacoGrowthRenewalTransitionRuntimeTest
  def membership_http(method, target, actor: @owner)
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! 'app.example.com'
    options = { headers: actor ? actor.create_new_auth_token : {}, as: :json }
    options[:params] = { agent: { role: 'agent' } } if method == :patch
    session.public_send(method, "/api/v1/accounts/#{@account.id}/agents/#{target.id}", **options)
    session.response
  end

  def test_membership_http_keeps_authentication_and_authorization_before_conflict
    membership_setup
    agent = create(:user, account: @account)
    @membership_test_users = [agent]
    posting_execution.prepare!
    membership_provider do
      assert_equal 401, membership_http(:patch, @owner, actor: nil).status
      assert_equal 401, membership_http(:patch, @owner, actor: agent).status
      response = membership_http(:patch, @owner)
      assert_equal 409, response.status
      assert response.parsed_body['error'].is_a?(String)
      refute_includes response.body, 'PostingExecution'
      assert @membership.reload.administrator?
      assert_empty @membership_calls
      posting_execution.cancel_prepared!
      assert_equal 200, membership_http(:patch, @owner).status
      assert @membership.reload.agent?
      assert_includes @membership_calls, :demote
    end
  end

  def test_membership_http_delete_retains_member_until_provider_result_is_definitive
    membership_setup
    target = create(:user, account: @account)
    @membership_test_users = [target]
    target_membership = AccountUser.find_by!(user_id: target.id, account_id: @account.id)
    posting_execution.prepare!
    posting_execution.start!
    posting_execution.mark_uncertain!
    membership_provider do
      assert_equal 409, membership_http(:delete, target).status
      assert AccountUser.exists?(target_membership.id)
      assert User.exists?(target.id)
      assert_empty @membership_calls
      posting_execution.complete!(outcome: 'rejected', evidence_hash: 'e' * 64)
      assert_equal 200, membership_http(:delete, target).status
      refute AccountUser.exists?(target_membership.id)
      assert_includes @membership_calls, :revoke
    end
  end
end

class ToybacoGrowthRenewalTransitionRuntimeTest
  # posting-principal-tests-begin
  Principal = Toybaco::Growth::PostingPrincipal
  PrincipalRow = Toybaco::GrowthPostingPrincipal

  def principal_refresh(actor_id: @owner.id)
    @execution_request['principal'] = Principal.capture!(@account.id, actor_id: actor_id, now: NOW)
  end

  def test_principal_demotion_and_restoration_do_not_restore_old_permission
    membership_setup
    old = @execution_request['principal'].deep_dup
    membership_provider do
      @membership.update!(role: :agent)
      @membership.update!(role: :administrator)
    end
    assert_equal 'administrator', @membership.reload.role
    assert_raises(ExecutionContext::Invalid) { posting_execution.prepare! }
    current = principal_refresh
    assert_equal old['members'].first['generation'] + 2, current['members'].first['generation']
    refute_equal old['members'].first['epoch'], current['members'].first['epoch']
    assert_equal 'prepared', posting_execution.prepare!['state']
  end

  def test_principal_deleted_membership_is_not_reused_after_rejoining
    membership_setup
    old = @execution_request['principal'].deep_dup
    membership_provider do
      @membership.destroy!
      # The upstream removal job must finish before the same user rejoins.
      Agents::DestroyJob.perform_now(@account, @owner)
      assert_equal 0, NotificationSetting.where(account_id: @account.id, user_id: @owner.id).count
      assert_equal 1, PrincipalRow.where(account_id: @account.id, user_id: @owner.id).count
      @membership = AccountUser.create!(account: @account, user: @owner, role: :administrator)
    end
    assert_raises(ExecutionContext::Invalid) { posting_execution.prepare! }
    current = principal_refresh
    refute_equal old['members'].first['membership_id'], current['members'].first['membership_id']
    assert_operator current['members'].first['generation'], :>, old['members'].first['generation']
    assert_equal 1, PrincipalRow.where(account_id: @account.id, user_id: @owner.id).count
    assert_equal 'prepared', posting_execution.prepare!['state']
  end

  def test_principal_identity_and_contract_restoration_do_not_revive_old_receipt
    membership_setup
    membership_provider do
      @owner.update!(provider: 'google_oauth2')
      @owner.update!(provider: 'email')
    end
    assert_raises(ExecutionContext::Invalid) { posting_execution.prepare! }
    principal_refresh
    before = @account.reload.internal_attributes.deep_dup
    @account.update!(internal_attributes: before.merge('toybaco_subscription_id' => 'sub_otherprincipal'))
    @account.update!(internal_attributes: before)
    assert_equal @execution_request['contract_hash'], ExecutionContext.contract_hash(@account.reload)
    assert_raises(ExecutionContext::Invalid) { posting_execution.prepare! }
    principal_refresh
    assert_equal 'prepared', posting_execution.prepare!['state']
  end

  def test_principal_normal_settings_and_same_contract_grace_preserve_receipt
    membership_setup
    original = @execution_request['principal'].deep_dup
    @membership.update!(auto_offline: false)
    membership_provider { @owner.update!(name: 'Updated display', ui_settings: { 'locale' => 'ja' }) }
    @account.update!(name: 'Updated account', internal_attributes: @account.internal_attributes.merge('toybaco_billing_status' => 'past_due'))
    assert_equal original, principal_refresh
    assert_equal 'prepared', posting_execution.prepare!['state']
  end

  def test_principal_membership_failure_rolls_back_epoch_and_role
    membership_setup
    original = @execution_request['principal'].deep_dup
    membership_provider do
      assert_raises(RuntimeError) do
        AccountUser.transaction do
          @membership.update!(role: :agent)
          raise 'fixture rollback'
        end
      end
    end
    assert_equal 'administrator', @membership.reload.role
    assert_equal original, principal_refresh
    assert_equal 'prepared', posting_execution.prepare!['state']
  end

  def test_principal_actor_can_use_existing_agent_role_without_changing_owner
    membership_setup
    actor = create(:user)
    @membership_test_users = [actor]
    member = nil
    membership_provider { member = AccountUser.create!(account: @account, user: actor, role: :agent) }
    before = principal_refresh(actor_id: actor.id).deep_dup
    assert_equal [@owner.id, actor.id].sort, before['members'].map { |item| item['user_id'] }
    membership_provider { member.update!(role: :administrator) }
    assert_raises(ExecutionContext::Invalid) { posting_execution.prepare! }
    after = principal_refresh(actor_id: actor.id)
    assert_equal before['members'].find { |item| item['user_id'] == @owner.id }, after['members'].find { |item| item['user_id'] == @owner.id }
    assert_equal 'prepared', posting_execution.prepare!['state']
  end

  def test_principal_rejects_missing_owner_and_foreign_actor_and_outer_transaction
    membership_setup
    foreign = create(:user)
    @membership_test_users = [foreign]
    [nil, 0, '1', foreign.id].each do |id|
      assert_raises(ExecutionContext::Invalid) { Principal.capture!(@account.id, actor_id: id, now: NOW) }
    end
    Account.transaction do
      assert_raises(ExecutionContext::Invalid) { Principal.capture!(@account.id, actor_id: @owner.id, now: NOW) }
    end
    membership_provider { @membership.update!(role: :agent) }
    assert_raises(ExecutionContext::Invalid) { principal_refresh }
    assert_empty ExecutionRow.where(account_id: @account.id)
  end

  def test_principal_old_request_version_and_tampered_receipts_never_start
    membership_setup
    assert_raises(ExecutionContext::Invalid) { posting_execution(request: @execution_request.merge('version' => 1)).prepare! }
    original = @execution_request['principal'].deep_dup
    [original.merge('actor_id' => @owner.id + 1), original.merge('extra' => true), original.merge('members' => []),
     original.merge('account_id' => @account.id + 1), nil].each do |bad|
      assert_raises(ExecutionContext::Invalid) { posting_execution(request: @execution_request.merge('principal' => bad)).prepare! }
    end
    assert_empty ExecutionRow.where(account_id: @account.id)
    posting_execution.prepare!
    row = PrincipalRow.find_by!(account_id: @account.id, user_id: @owner.id)
    row.update!(epoch: 'f' * 64, updated_at: NOW)
    assert_raises(ExecutionContext::Invalid) { posting_execution.start! }
    assert_equal 'prepared', ExecutionRow.find_by!(account_id: @account.id).state
  end

  def test_principal_missing_or_future_epoch_is_not_silently_repaired
    membership_setup
    row = PrincipalRow.find_by!(account_id: @account.id, user_id: @owner.id)
    row.update!(updated_at: NOW + 1)
    assert_raises(ExecutionContext::Invalid) { principal_refresh }
    assert_raises(ExecutionContext::Invalid) { posting_execution.prepare! }
    row.delete
    assert_raises(ExecutionContext::Invalid) { posting_execution.prepare! }
    original = @execution_request['principal'].deep_dup
    renewed = Principal.capture!(@account.id, actor_id: @owner.id, now: NOW)
    refute_equal original['members'].first['epoch'], renewed['members'].first['epoch']
    assert_raises(ExecutionContext::Invalid) { posting_execution.prepare! }
  end

  def test_principal_capture_and_revocation_are_serialized_on_account
    membership_setup
    original = @execution_request['principal'].deep_dup
    entered = Queue.new
    release = Queue.new
    membership_provider do
      worker = Thread.new do
        Account.connection_pool.with_connection do
          AccountUser.transaction do
            AccountUser.find(@membership.id).update!(role: :agent)
            entered << true
            release.pop
          end
        end
      end
      Timeout.timeout(5) { entered.pop }
      assert_raises(ExecutionContext::Busy) { principal_refresh }
      assert_raises(ExecutionContext::Busy) { posting_execution.prepare! }
      release << true
      Timeout.timeout(5) { worker.value }
      @membership.reload.update!(role: :administrator)
    ensure
      release << true
      worker&.join(5)
    end
    assert_raises(ExecutionContext::Invalid) { posting_execution.prepare! }
    refute_equal original, principal_refresh
  end
  def test_principal_direct_identity_revocations_rotate_and_rollback_with_account
    membership_setup
    operations = [-> { Toybaco::PostizSync.demote_membership!(user_id: @owner.id, account: @account) },
                  -> { Toybaco::PostizSync.revoke_membership!(user_id: @owner.id, account: @account) },
                  -> { Toybaco::PostizSync.disable_account!(account: @account) },
                  -> { Toybaco::PostizSync.disable_user!(user_id: @owner.id) }]
    Toybaco::PostizSync.stub(:configured?, true) do
      operations.each do |operation|
        original = principal_refresh.deep_dup
        Toybaco::PostizSync.stub(:with_transaction, ->(*) { raise 'external fixture failure' }) do
          assert_raises(RuntimeError, &operation)
        end
        assert_equal original, principal_refresh
        Toybaco::PostizSync.stub(:with_transaction, ->(*) { :external_fixture_success }) { operation.call }
        assert_raises(ExecutionContext::Invalid) { posting_execution.prepare! }
        current = principal_refresh.deep_dup
        refute_equal original, current
        Toybaco::PostizSync.stub(:sync_under_identity_lock, ->(*) { :synchronized }) do
          assert_equal :synchronized, Toybaco::PostizSync.sync!(user: @owner, account: @account)
        end
        assert_equal current, principal_refresh
      end
    end
    assert_empty ExecutionRow.where(account_id: @account.id)
  end

  # posting-principal-tests-end
  # posting-preparation-tests-begin
  Preparation = Toybaco::Growth::PostingPreparation
  PreparationRecord = Toybaco::Growth::PostingPreparationRecord
  PreparationRow = Toybaco::GrowthPostingPreparation

  def prepare_posting_preparation
    travel_to NOW
    original = method(:posting_receipt)
    transport = lambda do |payload|
      policy = { 'organizationId' => payload['organization_id'], 'transitionId' => payload['transition_id'],
        'keepIntegrationIds' => payload['keep_integration_ids'], 'scheduledPostsPerAccount' => payload['scheduled_posts_per_account'] }
      hash = Digest::SHA256.hexdigest(JSON.generate([payload['policy_hash'], [], [], []]))
      @posting_source_value = { 'organizationId' => payload['organization_id'], 'transitionId' => payload['transition_id'],
        'policyHash' => payload['policy_hash'], 'receiptHash' => hash, 'policy' => policy.merge('policyHash' => payload['policy_hash']),
        'keepIntegrationIds' => [], 'keepPostIds' => [], 'heldPostIds' => [] }
      original.call(payload).merge('receipt_hash' => hash, 'kept_posts' => 0, 'held_posts' => 0)
    end
    stub(:posting_receipt, transport) { prepare_inbox_release }
    @account.with_lock do
      @account.update_columns(internal_attributes: @account.internal_attributes.merge('postiz' => {
        'enabled' => true, 'organization_id' => Toybaco::PostizSync.deterministic_organization_id(@account.id) }))
    end
    @preparation_connections = []
    @preparation_read_checks = []
    @preparation_ids = %w[channel-a channel-b]
  end

  def preparation_database
    config = Account.connection_pool.db_config.configuration_hash
    db = PG.connect(host: config[:host], port: config[:port], dbname: config[:database], user: config[:username], password: config[:password])
    @preparation_connections << db
    db.exec('CREATE TEMP TABLE "Integration" (id text, name text, "organizationId" text, "createdAt" timestamp, "deletedAt" timestamp)')
    db.exec('ALTER TABLE "Integration" ADD COLUMN "internalId" text, ADD COLUMN "providerIdentifier" text, ADD COLUMN disabled boolean DEFAULT false')
    db.exec('CREATE TYPE pg_temp."Provider" AS ENUM (\'GENERIC\')')
    db.exec('SET search_path TO pg_temp, public')
    db.exec('CREATE TEMP TABLE "Post" (id text, "integrationId" text, "organizationId" text, "publishDate" timestamp, "deletedAt" timestamp, "parentPostId" text, state text)')
    db.exec('CREATE TEMP TABLE "ToybacoPostingRetention" ("organizationId" text, "transitionId" text, "policyHash" text, "receiptHash" text, policy jsonb, "keepIntegrationIds" jsonb, "keepPostIds" jsonb, "heldPostIds" jsonb)')
    db.exec('CREATE TEMP TABLE "ToybacoPostingRetentionHistory" ("organizationId" text, "transitionId" text, generation integer, "receiptHash" text, receipt jsonb)')
    db.exec('CREATE TEMP TABLE "User" (id text, "providerName" "Provider", "providerId" text, activated boolean, "deletedAt" timestamp)')
    db.exec('CREATE TEMP TABLE "UserOrganization" (id text, "userId" text, "organizationId" text, role text, disabled boolean)')
    db.exec('CREATE TEMP TABLE "Organization" (id text, "deletedAt" timestamp)')
    value = @posting_source_value
    org = value['organizationId']; uid = Toybaco::PostizSync.deterministic_user_id(@owner.id)
    @preparation_ids.each { |id| db.exec_params('INSERT INTO "Integration" (id,name,"organizationId","createdAt","deletedAt") VALUES ($1,$2,$3,$4,NULL)', [id, 'not stored', org, NOW]) }
    db.exec_params('INSERT INTO "Integration" (id,name,"organizationId","createdAt","deletedAt") VALUES ($1,$2,$3,$4,NULL)', ['foreign', 'not stored', 'foreign-org', NOW])
    db.exec_params('INSERT INTO "ToybacoPostingRetention" VALUES ($1,$2,$3,$4,$5::jsonb,$6::jsonb,$7::jsonb,$8::jsonb)',
      value.values.map { |v| v.is_a?(Array) || v.is_a?(Hash) ? JSON.generate(v) : v })
    db.exec_params('INSERT INTO "ToybacoPostingRetentionHistory" VALUES ($1,$2,1,$3,$4::jsonb)', [org, value['transitionId'], value['receiptHash'], JSON.generate(value)])
    db.exec_params('INSERT INTO "Organization" VALUES ($1,NULL)', [org])
    db.exec_params('INSERT INTO "User" VALUES ($1,\'GENERIC\',$2,true,NULL)', [uid, "cw:#{@owner.id}"])
    db.exec_params('INSERT INTO "UserOrganization" VALUES ($1,$2,$3,\'ADMIN\',false)', ['membership-fixture', uid, org])
    db.exec('CREATE TEMP TABLE "ToybacoPostingIdentityEpoch" (kind text, "entityId" text, generation bigint, epoch uuid)')
    subjects = [['Organization', org], ['User', uid], ['UserOrganization', 'membership-fixture']] + @preparation_ids.map { |id| ['Integration', id] }
    subjects.each do |kind, id|
      db.exec_params('INSERT INTO "ToybacoPostingIdentityEpoch" VALUES ($1,$2,1,$3)', [kind, id, '11111111-1111-4111-8111-111111111111'])
    end
    @preparation_db_change&.call(db)
    checks = @preparation_read_checks
    original = db.method(:exec_params)
    db.define_singleton_method(:exec_params) do |*args|
      checks << [exec('SHOW transaction_read_only').getvalue(0, 0), exec('SHOW transaction_isolation').getvalue(0, 0)]
      original.call(*args)
    end
    db
  rescue Exception
    db&.close unless db&.finished?
    raise
  end

  def preparation_service(user: @owner, enabled: true, now: NOW)
    Preparation.new(@account, user, client: @release_provider, now: now,
      environment: bridge_environment.merge('TOYBACO_POSTING_RELEASE_ENABLED' => enabled ? 'true' : 'false')) { preparation_database }
  end

  def prepare_posting(ids = ['channel-a'], id: 'e' * 64, revision: nil)
    service = preparation_service
    service.prepare!(integration_ids: ids, revision: revision || service.read['revision'], request_id: id)
  end

  def test_posting_preparation_reads_real_postiz_snapshot_and_persists_only_non_executable_choice
    prepare_posting_preparation
    before = @account.reload.internal_attributes.deep_dup
    result = prepare_posting
    assert_equal 'prepared', result['state']
    refute result['execute']
    assert_equal ['channel-a'], result.dig('receipt', 'keep_ids')
    assert_equal 1, result.dig('receipt', 'posting', 'generation')
    assert_equal @owner.id, result.dig('receipt', 'principal', 'actor_id')
    assert_equal before, @account.reload.internal_attributes
    assert_empty ExecutionRow.where(account_id: @account.id)
    assert_equal [false], @release_reads
    assert @preparation_connections.all?(&:finished?)
    assert @preparation_read_checks.all? { |row| row == ['on', 'repeatable read'] }
    row = PreparationRow.find_by!(account_id: @account.id)
    assert_raises(ActiveRecord::ReadOnlyRecord) { row.update!(receipt: row.receipt.merge('prepared_at' => 1)) }
    refute_includes JSON.generate(row.receipt), 'not stored'
    refute row.receipt.dig('posting').key?('available_ids')
  end

  def test_posting_preparation_replay_preserves_original_without_reactivating_after_contract_change
    prepare_posting_preparation
    view = preparation_service.read
    result = prepare_posting(revision: view['revision'])
    @account.update!(internal_attributes: @account.internal_attributes.merge('toybaco_subscription_id' => 'sub_newer'))
    @release_reads.clear
    assert_equal result, prepare_posting(revision: view['revision'])
    assert_empty @release_reads
    assert_equal 1, PreparationRow.where(account_id: @account.id).count
    assert_raises(PreparationRecord::Invalid) { prepare_posting(['channel-b'], revision: view['revision']) }
    assert_equal 'sub_newer', @account.reload.internal_attributes['toybaco_subscription_id']
  end

  def test_posting_preparation_rejects_foreign_duplicate_unsorted_missing_and_over_limit_selection
    prepare_posting_preparation
    @preparation_ids = (1..7).map { |i| "channel-#{i}" }
    revision = preparation_service.read['revision']
    [['foreign'], ['missing'], ['channel-1', 'channel-1'], %w[channel-2 channel-1], @preparation_ids].each do |ids|
      assert_raises(PreparationRecord::Invalid) { prepare_posting(ids, revision: revision) }
    end
    assert_empty PreparationRow.where(account_id: @account.id)
    assert_empty @release_reads
  end

  def test_posting_preparation_rejects_disabled_or_wrong_postiz_membership_and_broken_history
    prepare_posting_preparation
    ["UPDATE \"UserOrganization\" SET disabled=true", "UPDATE \"UserOrganization\" SET role='USER'",
     "UPDATE \"User\" SET \"providerId\"='cw:other'", 'DELETE FROM "ToybacoPostingRetentionHistory"',
     'UPDATE "ToybacoPostingRetentionHistory" SET generation=2', 'DELETE FROM "Organization"'].each do |sql|
      @preparation_db_change = ->(db) { db.exec(sql) }
      assert_raises(PreparationRecord::Invalid) { preparation_service.read }
    end
    assert @preparation_connections.all?(&:finished?)
    assert_empty PreparationRow.where(account_id: @account.id)
  end

  def test_posting_preparation_rejects_unknown_queue
    prepare_posting_preparation
    @preparation_db_change = lambda do |db|
      db.exec_params('INSERT INTO "Post" VALUES (\'unexpected\',\'channel-a\',$1,$2,NULL,NULL,\'QUEUE\')', [@posting_source_value['organizationId'], NOW])
    end
    assert_raises(PreparationRecord::Invalid) { preparation_service.read }
    assert_empty PreparationRow.where(account_id: @account.id)
  end

  def test_posting_preparation_rechecks_membership_contract_and_postiz_selection_after_stripe
    prepare_posting_preparation
    revision = preparation_service.read['revision']
    @release_provider.callback = -> { @preparation_ids.delete('channel-a') }
    assert_raises(PreparationRecord::Invalid) { prepare_posting(revision: revision) }
    assert_empty PreparationRow.where(account_id: @account.id)
    @preparation_ids << 'channel-a'
    @release_provider.callback = lambda do
      Thread.new do
        Account.connection_pool.with_connection do
          member = AccountUser.find_by!(account: @account, user: @owner)
          member.update!(role: 'agent')
          member.update!(role: 'administrator')
        end
      end.value
    end
    Toybaco::PostizSync.stub(:demote_membership!, true) do
      assert_raises(PreparationRecord::Invalid) { prepare_posting(revision: revision) }
    end
    assert_empty PreparationRow.where(account_id: @account.id)
    revision = preparation_service.read['revision']
    @release_provider.callback = lambda do
      Thread.new do
        Account.connection_pool.with_connection do
          account = Account.find(@account.id)
          original = account.internal_attributes.deep_dup
          account.update!(internal_attributes: original.merge('toybaco_subscription_id' => 'sub_duringread'))
          account.update!(internal_attributes: original)
        end
      end.value
    end
    assert_raises(PreparationRecord::Invalid) { prepare_posting(revision: revision) }
    assert_empty PreparationRow.where(account_id: @account.id)
  end

  def test_posting_preparation_rejects_unpaid_or_mismatched_stripe_and_expired_coverage
    prepare_posting_preparation
    original = @release_provider.sub.deep_dup
    [original.merge('status' => 'past_due'), original.merge('customer' => 'cus_foreign'),
     original.merge('livemode' => true), original.merge('pause_collection' => {})].each do |sub|
      @release_provider.sub = sub
      assert_raises(PreparationRecord::Invalid) { prepare_posting }
    end
    @release_provider.sub = original
    assert_raises(PreparationRecord::Invalid) { preparation_service(now: NOW + 1.year).read }
    assert_empty PreparationRow.where(account_id: @account.id)
  end

  def test_posting_preparation_is_closed_to_agents_and_outer_transactions
    prepare_posting_preparation
    assert_raises(PreparationRecord::Invalid) { preparation_service(enabled: false).read }
    Account.transaction { assert_raises(PreparationRecord::Invalid) { preparation_service.read } }
    member = AccountUser.find_by!(account: @account, user: @owner)
    Toybaco::PostizSync.stub(:demote_membership!, true) { member.update!(role: 'agent') }
    assert_raises(PreparationRecord::Invalid) { preparation_service.read }
    assert_empty PreparationRow.where(account_id: @account.id)
  end

  def test_posting_preparation_record_failure_rolls_back_and_same_request_can_be_retried
    prepare_posting_preparation
    view = preparation_service.read
    PreparationRow.stub(:create!, ->(**) { raise ActiveRecord::StatementInvalid, 'fixture' }) do
      assert_raises(ActiveRecord::StatementInvalid) { prepare_posting(revision: view['revision']) }
    end
    assert_empty PreparationRow.where(account_id: @account.id)
    result = prepare_posting(revision: view['revision'])
    assert_equal result, prepare_posting(revision: view['revision'])
    assert_equal 1, PreparationRow.where(account_id: @account.id).count
  end

  def test_posting_preparation_refuses_pending_stop_without_creating_an_authority
    prepare_posting_preparation
    source_hash = ExecutionContext.contract_hash(@account.reload)
    target_hash = ExecutionContext.digest(ExecutionContext.binding('suspended', @account.internal_attributes))
    posting_stop(contract_hash: source_hash, target_hash: target_hash).request!
    assert_raises(Toybaco::Growth::PostingStopContext::Busy) { preparation_service.read }
    assert_empty PreparationRow.where(account_id: @account.id)
  end

  def test_posting_preparation_rejects_same_id_provider_target_change_during_provider_read
    prepare_posting_preparation
    revision = preparation_service.read['revision']
    @release_provider.callback = lambda do
      @preparation_db_change = ->(db) { db.exec(%q{UPDATE "Integration" SET "internalId"='different-provider-account' WHERE id='channel-a'}) }
    end
    assert_raises(PreparationRecord::Invalid) { prepare_posting(revision: revision) }
    assert_empty PreparationRow.where(account_id: @account.id)
  end

  def test_posting_preparation_replay_refuses_corrupt_future_or_foreign_record
    prepare_posting_preparation
    result = prepare_posting
    receipt = result.fetch('receipt')
    row = PreparationRow.find_by!(account_id: @account.id)
    [receipt.merge('keep_ids' => ['foreign']), receipt.merge('prepared_at' => NOW.to_i + 1),
     receipt.merge('account_id' => @account.id + 1), receipt.merge('principal' => nil),
     receipt.merge('posting' => receipt['posting'].merge('owner' => { 'user_id' => 'foreign' }))].each do |broken|
      hash = PreparationRecord.digest(broken.except('receipt_hash'))
      PreparationRow.where(id: row.id).update_all(receipt: broken.merge('receipt_hash' => hash))
      assert_raises(PreparationRecord::Invalid) { prepare_posting(revision: receipt['revision']) }
    end
  end
  def test_posting_preparation_exports_a_minimal_non_executable_postiz_request
    prepare_posting_preparation
    receipt = prepare_posting.fetch('receipt')
    request = Toybaco::Growth::PostingPreparationExport.request(receipt, @account.id, now: NOW)
    vector = { 'z' => [true, nil, 1_893_456_000_123_000, { 'b' => 'f', 'a' => '接続😀' }], 'a' => '2026-09-24 00:00:00.123456' }
    assert_equal '8c65029c816ed93c39aa4808fd29fa4903564512d148d0293f44f8c62021c58f', PreparationRecord.digest(vector)
    assert_equal receipt['request_id'], request['requestId']
    assert_equal receipt['receipt_hash'], request['railsReceiptHash']
    assert_equal receipt.dig('posting', 'inventory_hash'), request['inventoryHash']
    assert_equal PreparationRecord.digest(receipt['principal']), request['principalHash']
    assert_equal @owner.id, request['actorId']
    assert_equal ['channel-a'], request['requestedIntegrationIds']
    assert_equal 6, request['postingAccountLimit']
    refute request.keys.any? { |key| key.match?(/token|customer|subscription|nonce|execute|binding/i) }
    assert_raises(PreparationRecord::Invalid) { Toybaco::Growth::PostingPreparationExport.request(receipt.merge('owner_id' => @owner.id + 1), @account.id, now: NOW) }
    assert_raises(PreparationRecord::Invalid) { Toybaco::Growth::PostingPreparationExport.request(receipt, @account.id + 1, now: NOW) }
    assert_equal @account.internal_attributes, @account.reload.internal_attributes
  end

  def test_posting_preparation_keeps_validated_selection_during_stripe_read
    prepare_posting_preparation
    ids = ['channel-a'.dup]
    request_id = 'b' * 64
    revision = preparation_service.read['revision']
    original_revision = revision.dup
    @release_provider.callback = lambda do
      ids.first.replace('foreign')
      request_id.replace('c' * 64)
      revision.replace('d' * 64)
    end
    result = preparation_service.prepare!(integration_ids: ids, revision: revision, request_id: request_id)
    assert_equal ['channel-a'], result.dig('receipt', 'requested_ids')
    assert_equal 'b' * 64, result.dig('receipt', 'request_id')
    assert_equal original_revision, result.dig('receipt', 'revision')
    refute result['execute']
    assert_equal ['channel-a'], PreparationRow.find_by!(account_id: @account.id).receipt['requested_ids']
  end

  # posting-preparation-tests-end


  # posting-preparation-delivery-tests-begin
  PreparationDelivery = Toybaco::Growth::PostingPreparationDelivery
  PreparationAckRow = Toybaco::GrowthPostingPreparationAck
  PreparationProtocol = Toybaco::Growth::PostingPreparationProtocol

  def preparation_response(payload)
    input = payload.fetch('preparation')
    receipt = { 'version' => 2, 'organizationId' => input['organizationId'], 'requestId' => input['requestId'],
      'payloadHash' => PreparationRecord.digest(input), 'preparedAt' => NOW.to_i * 1000, 'state' => 'prepared', 'execute' => false }
    receipt['receiptHash'] = PreparationRecord.digest(receipt)
    { 'version' => 2, 'request_sha256' => Digest::SHA256.hexdigest(JSON.generate(payload)), 'preparation' => receipt }
  end

  def preparation_delivery(transport, user: @owner, environment: bridge_environment.merge('TOYBACO_POSTING_RELEASE_ENABLED' => 'true'))
    PreparationDelivery.new(@account, user, environment: environment, clock: -> { NOW }, transport: transport)
  end

  def test_preparation_delivery_persists_separate_immutable_ack_outside_http_and_replays_history
    prepare_posting_preparation
    prepared = prepare_posting['receipt']
    before = @account.reload.internal_attributes.deep_dup
    calls = []
    service = preparation_delivery(lambda do |payload|
      calls << payload.deep_dup
      refute Account.connection.transaction_open?
      preparation_response(payload)
    end)
    result = service.call(request_id: prepared['request_id'])
    assert_equal 'prepared', result['state']; refute result['execute']
    assert_equal prepared['receipt_hash'], result.dig('receipt', 'preparation_hash')
    assert_equal prepared, PreparationRow.find_by!(account_id: @account.id).receipt
    assert_equal before, @account.reload.internal_attributes
    row = PreparationAckRow.find_by!(account_id: @account.id)
    assert_equal NOW, row.created_at; assert_equal NOW, row.updated_at
    assert_raises(ActiveRecord::ReadOnlyRecord) { row.update!(receipt: row.receipt.merge('confirmed_at' => 1)) }
    assert_raises(ActiveRecord::RecordNotUnique) { PreparationAckRow.create!(account_id: @account.id, request_id: prepared['request_id'], receipt: row.reload.receipt, created_at: NOW, updated_at: NOW) }
    @account.update!(internal_attributes: before.merge('toybaco_subscription_id' => 'sub_next'))
    assert_equal result, service.call(request_id: prepared['request_id'])
    assert_equal 1, calls.size
    assert_empty ExecutionRow.where(account_id: @account.id)
  end

  def test_preparation_delivery_recovers_lost_remote_response_with_identical_saved_payload
    prepare_posting_preparation
    prepared = prepare_posting['receipt']; calls = []; remote = nil
    service = preparation_delivery(lambda do |payload|
      calls << payload.deep_dup
      remote ||= preparation_response(payload)
      raise IOError, 'simulated response loss after remote commit' if calls.one?
      remote
    end)
    assert_raises(IOError) { service.call(request_id: prepared['request_id']) }
    assert_empty PreparationAckRow.where(account_id: @account.id)
    result = service.call(request_id: prepared['request_id'])
    assert_equal calls.first, calls.last
    assert_equal remote, result.dig('receipt', 'response')
    refute result['execute']; assert_equal 1, PreparationAckRow.where(account_id: @account.id).count
    assert_equal prepared, PreparationRow.find_by!(account_id: @account.id).receipt
  end

  def test_preparation_delivery_recovers_ack_write_failure_without_replacing_original_preparation
    prepare_posting_preparation
    prepared = prepare_posting['receipt']; responses = []
    service = preparation_delivery(->(payload) { responses << preparation_response(payload); responses.last })
    original_create = PreparationAckRow.method(:create!)
    PreparationAckRow.stub(:create!, ->(**attrs) { original_create.call(**attrs); raise 'simulated acknowledgement failure after insert' }) do
      assert_raises(RuntimeError) { service.call(request_id: prepared['request_id']) }
    end
    assert_empty PreparationAckRow.where(account_id: @account.id)
    assert_equal prepared, PreparationRow.find_by!(account_id: @account.id).receipt
    result = service.call(request_id: prepared['request_id'])
    assert_equal 2, responses.size; assert_equal responses.first, responses.last
    assert_equal prepared['receipt_hash'], result.dig('receipt', 'preparation_hash')
    refute result['execute']
  end

  def test_preparation_delivery_rejects_unsigned_semantic_corruption_and_never_saves_ack
    prepare_posting_preparation
    prepared = prepare_posting['receipt']
    [{'execute' => true}, {'state' => 'active'}, {'payloadHash' => 'a' * 64}, {'organizationId' => 'foreign'},
     {'requestId' => 'b' * 64}, {'preparedAt' => (NOW.to_i + 61) * 1000}, {'extra' => true}].each do |change|
      service = preparation_delivery(lambda do |payload|
        response = preparation_response(payload); receipt = response['preparation'].merge(change)
        receipt['receiptHash'] = PreparationRecord.digest(receipt.except('receiptHash'))
        response.merge('preparation' => receipt)
      end)
      assert_raises(PreparationRecord::Invalid) { service.call(request_id: prepared['request_id']) }
    end
    assert_empty PreparationAckRow.where(account_id: @account.id)
    assert_empty ExecutionRow.where(account_id: @account.id)
  end

  def test_preparation_delivery_contract_change_during_http_leaves_only_non_executable_remote_history
    prepare_posting_preparation
    prepared = prepare_posting['receipt']; calls = 0
    service = preparation_delivery(lambda do |payload|
      calls += 1
      @account.reload.update!(internal_attributes: @account.internal_attributes.merge('toybaco_subscription_id' => 'sub_changed'))
      preparation_response(payload)
    end)
    assert_raises(PreparationRecord::Invalid, ExecutionContext::Invalid) { service.call(request_id: prepared['request_id']) }
    assert_raises(PreparationRecord::Invalid, ExecutionContext::Invalid) { service.call(request_id: prepared['request_id']) }
    assert_equal 1, calls
    assert_empty PreparationAckRow.where(account_id: @account.id)
    assert_equal prepared, PreparationRow.find_by!(account_id: @account.id).receipt
  end

  def test_preparation_delivery_principal_restore_during_http_does_not_revive_old_request
    prepare_posting_preparation
    prepared = prepare_posting['receipt']
    service = preparation_delivery(lambda do |payload|
      member = AccountUser.find_by!(account_id: @account.id, user_id: @owner.id)
      Toybaco::PostizSync.stub(:demote_membership!, true) do
        Toybaco::PostizLifecycle.stub(:reconcile_account_user, true) do
          member.update!(role: :agent); member.update!(role: :administrator)
        end
      end
      preparation_response(payload)
    end)
    assert_raises(PreparationRecord::Invalid, ExecutionContext::Invalid) { service.call(request_id: prepared['request_id']) }
    assert_empty PreparationAckRow.where(account_id: @account.id)
    assert_equal prepared, PreparationRow.find_by!(account_id: @account.id).receipt
  end

  def test_preparation_delivery_requires_saved_request_current_owner_mode_flag_and_no_outer_transaction
    prepare_posting_preparation
    prepared = prepare_posting['receipt']; none = ->(*) { flunk 'invalid admission cannot call HTTP' }
    assert_raises(PreparationRecord::Invalid) { preparation_delivery(none).call(request_id: 'f' * 64) }
    assert_raises(PreparationRecord::Invalid) { Account.transaction { preparation_delivery(none).call(request_id: prepared['request_id']) } }
    [{'TOYBACO_POSTING_RELEASE_ENABLED' => 'false'}, {'TOYBACO_STRIPE_MODE' => 'live'}, {'FRONTEND_URL' => 'https://foreign.invalid'}].each do |change|
      env = bridge_environment.merge('TOYBACO_POSTING_RELEASE_ENABLED' => 'true').merge(change)
      assert_raises(PreparationRecord::Invalid) { preparation_delivery(none, environment: env).call(request_id: prepared['request_id']) }
    end
    agent = create(:user, role: 'agent', account: @account); (@membership_test_users ||= []) << agent
    assert_raises(PreparationRecord::Invalid) { preparation_delivery(none, user: agent).call(request_id: prepared['request_id']) }
    assert_empty PreparationAckRow.where(account_id: @account.id)
  end

  def test_preparation_delivery_holds_shared_plan_change_lock_but_not_account_transaction_across_http
    prepare_posting_preparation
    prepared = prepare_posting['receipt']
    service = preparation_delivery(lambda do |payload|
      worker = Thread.new do
        Account.connection_pool.with_connection do
          Toybaco::Checkout::PlanChangeLock.call(Account.find(@account.id)) { :unexpected }
        rescue Toybaco::Checkout::PlanChangeError => error
          error
        end
      end
      raise 'lock probe timed out' unless worker.join(5)
      assert_instance_of Toybaco::Checkout::PlanChangeError, worker.value
      refute Account.connection.transaction_open?
      preparation_response(payload)
    end)
    refute service.call(request_id: prepared['request_id'])['execute']
  end

  def test_preparation_ack_corruption_and_wrong_database_timestamp_fail_before_retry
    prepare_posting_preparation
    prepared = prepare_posting['receipt']
    preparation_delivery(->(payload) { preparation_response(payload) }).call(request_id: prepared['request_id'])
    row = PreparationAckRow.find_by!(account_id: @account.id); original = row.receipt.deep_dup
    [original.merge('receipt_hash' => 'a' * 64), original.merge('confirmed_at' => NOW.to_i + 1),
     original.merge('preparation_hash' => 'b' * 64)].each do |corrupt|
      PreparationAckRow.where(id: row.id).update_all(receipt: corrupt)
      assert_raises(PreparationRecord::Invalid) { preparation_delivery(->(*) { flunk 'corrupt ack cannot retry' }).call(request_id: prepared['request_id']) }
    end
    PreparationAckRow.where(id: row.id).update_all(receipt: original, updated_at: NOW + 1)
    assert_raises(PreparationRecord::Invalid) { preparation_delivery(->(*) { flunk }).call(request_id: prepared['request_id']) }
  end

  def test_preparation_protocol_matches_typescript_and_rejects_cross_purpose_expiry_duplicates_and_reflection
    vector = JSON.parse(File.read(File.join(__dir__, 'fixtures/posting-preparation-protocol-v2.json')))
    body = vector.fetch('body'); now = Time.at(vector['stamp']).utc
    config = PreparationProtocol.configuration(bridge_environment.merge('TOYBACO_POSTING_RELEASE_ENABLED' => 'true'))
    assert_equal vector['request_signature'], PreparationProtocol.signature(JSON.generate(body), key: config[:key], now: now, direction: 'POST')
    raw = JSON.generate(vector['response'])
    header = PreparationProtocol.signature(raw, key: config[:key], now: now, direction: 'RESPONSE')
    assert_equal vector['response_signature'], header
    verify = ->(text, signature) { PreparationProtocol.response!(text, header: signature, key: config[:key], now: now, request: body) }
    assert_equal vector['response'], verify.call(raw, header)
    other = Toybaco::Growth::RetentionProtocol.configuration(bridge_environment)
    [PreparationProtocol.signature(raw, key: other[:key], now: now, direction: 'RESPONSE'),
     PreparationProtocol.signature(raw, key: config[:key], now: now - 61, direction: 'RESPONSE'),
     PreparationProtocol.signature(raw, key: config[:key], now: now, direction: 'POST')].each do |signature|
      assert_raises(PreparationRecord::Invalid) { verify.call(raw, signature) }
    end
    duplicate = raw.sub('"version":2', '"version":1,"version":2')
    signed = PreparationProtocol.signature(duplicate, key: config[:key], now: now, direction: 'RESPONSE')
    assert_raises(PreparationRecord::Invalid) { verify.call(duplicate, signed) }
  end
  def test_preparation_transport_uses_fixed_tls_origin_no_proxy_no_retry_and_bounded_signed_response
    protocol = PreparationProtocol
    request = JSON.parse(File.read(File.join(__dir__, 'fixtures/posting-preparation-protocol-v2.json')))['body']
    key = protocol.configuration(bridge_environment.merge('TOYBACO_POSTING_RELEASE_ENABLED' => 'true'))[:key]
    value = preparation_response(request); raw = JSON.generate(value)
    signature = protocol.signature(raw, key: key, now: NOW, direction: 'RESPONSE')
    response = Struct.new(:code, :content_type, :raw, :signature) do
      def [](name) = name == 'X-Toybaco-Preparation-Signature' ? signature : nil
      def read_body = yield raw
    end.new('200', 'application/json', raw, signature)
    http = Struct.new(:use_ssl, :open_timeout, :read_timeout, :write_timeout, :max_retries, :handler) do
      def start = yield
      def request(input) = yield handler.call(input)
    end.new
    observed = []
    http.handler = lambda do |input|
      observed << input
      assert_equal '/api/toybaco/internal/posting-preparation', input.path
      assert_equal 'application/json', input['Content-Type']
      assert_equal 'identity', input['Accept-Encoding']
      assert_equal JSON.generate(request), input.body
      assert_equal protocol.signature(input.body, key: key, now: NOW, direction: 'POST'), input['X-Toybaco-Preparation-Signature']
      response
    end
    factory = lambda do |host, port, proxy|
      assert_equal ['post.staging.toybaco.jp', 443, nil], [host, port, proxy]
      http
    end
    transport = Toybaco::Growth::RetentionTransport.new(environment: bridge_environment.merge('TOYBACO_POSTING_RELEASE_ENABLED' => 'true'), clock: -> { NOW }, protocol: protocol)
    Net::HTTP.stub(:new, factory) do
      assert_equal value, transport.call(request)
      assert_equal [true, 5, 10, 5, 0], [http.use_ssl, http.open_timeout, http.read_timeout, http.write_timeout, http.max_retries]
      response.code = '302'
      assert_raises(protocol::Invalid) { transport.call(request) }
      response.code = '200'; response.raw = 'x' * (protocol::MAX_BYTES + 1)
      assert_raises(protocol::Invalid) { transport.call(request) }
      response.raw = raw; response.signature = 'invalid'
      assert_raises(protocol::Invalid) { transport.call(request) }
    end
    assert_equal 4, observed.size
  end

  # posting-preparation-delivery-tests-end

  def test_posting_identity_actual_reader_matches_canonical_decimal_string_vector
    prepare_posting_preparation
    vector = JSON.parse(File.read(File.join(__dir__, 'fixtures/posting-identity-v2.json')))
    db = preparation_database
    vector['identities'].each do |row|
      db.exec_params('INSERT INTO "ToybacoPostingIdentityEpoch" VALUES ($1,$2,$3,$4)', row.values_at('kind', 'entityId', 'generation', 'epoch'))
    end
    db.exec('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY')
    subjects = vector['identities'].map { |row| row.values_at('kind', 'entityId') }
    assert_equal vector['identity_hash'], Toybaco::Growth::PostingIdentitySnapshot.read(db, subjects.reverse)
    db.exec('ROLLBACK')
    invalid = Toybaco::Growth::RetentionPlan::Invalid
    [[], subjects + [subjects.first], [['User', 'bad value']], [['unknown', 'id']]].each do |input|
      assert_raises(invalid) { Toybaco::Growth::PostingIdentitySnapshot.read(db, input) }
    end
  ensure
    db&.close unless db&.finished?
  end

  def test_posting_identity_missing_exhausted_and_duplicate_rows_fail_closed
    prepare_posting_preparation
    [%q(DELETE FROM "ToybacoPostingIdentityEpoch" WHERE kind='User'),
     %q(UPDATE "ToybacoPostingIdentityEpoch" SET generation=9223372036854775807 WHERE kind='User'),
     %q(UPDATE "ToybacoPostingIdentityEpoch" SET generation=0 WHERE kind='User'),
     %q(UPDATE "ToybacoPostingIdentityEpoch" SET epoch='11111111-1111-1111-8111-111111111111' WHERE kind='User'),
     %q(INSERT INTO "ToybacoPostingIdentityEpoch" SELECT * FROM "ToybacoPostingIdentityEpoch" WHERE kind='User')].each do |sql|
      @preparation_db_change = ->(db) { db.exec(sql) }
      assert_raises(PreparationRecord::Invalid) { preparation_service.read }
    end
    assert_empty PreparationRow.where(account_id: @account.id)
  end

  def test_posting_identity_changes_revision_even_when_business_values_are_restored
    prepare_posting_preparation
    original = preparation_service.read
    @preparation_db_change = ->(db) { db.exec(%q(UPDATE "ToybacoPostingIdentityEpoch" SET generation=3 WHERE kind='UserOrganization')) }
    current = preparation_service.read
    refute_equal original['revision'], current['revision']
    assert_equal original['available_ids'], current['available_ids']
    assert_raises(PreparationRecord::Invalid) do
      preparation_service.prepare!(integration_ids: ['channel-a'], revision: original['revision'], request_id: '9' * 64)
    end
    result = preparation_service.prepare!(integration_ids: ['channel-a'], revision: current['revision'], request_id: '9' * 64)
    refute result['execute']
    assert_equal 2, result.dig('receipt', 'version')
    assert_equal result.dig('receipt', 'posting', 'identity_hash'), Toybaco::Growth::PostingPreparationExport.request(result['receipt'], @account.id, now: NOW)['identityHash']
  end

  def test_posting_preparation_v1_record_and_v1_ack_are_not_silently_upgraded
    prepare_posting_preparation
    prepared = prepare_posting['receipt']
    old = prepared.merge('version' => 1)
    old['receipt_hash'] = PreparationRecord.digest(old.except('receipt_hash'))
    assert_raises(PreparationRecord::Invalid) { PreparationRecord.validate!(old, @account.id, now: NOW) }
    ack = preparation_delivery(->(payload) { preparation_response(payload) }).call(request_id: prepared['request_id'])['receipt']
    old = ack.merge('version' => 1)
    old['receipt_hash'] = PreparationRecord.digest(old.except('receipt_hash'))
    refute Toybaco::Growth::PostingPreparationAck.header?(old)
  end

  def test_posting_preparation_rechecks_postiz_identity_epoch_after_stripe_read
    prepare_posting_preparation
    revision = preparation_service.read['revision']
    @release_provider.callback = lambda do
      @preparation_db_change = ->(db) { db.exec(%q(UPDATE "ToybacoPostingIdentityEpoch" SET generation=3 WHERE kind='Integration')) }
    end
    assert_raises(PreparationRecord::Invalid) { prepare_posting(revision: revision) }
    assert_empty PreparationRow.where(account_id: @account.id)
  end

end
