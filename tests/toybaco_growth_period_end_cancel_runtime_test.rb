# frozen_string_literal: true

require 'rails/test_help'
require 'minitest/mock'
require 'factory_bot_rails'
require_relative 'toybaco_growth_purchase_stripe_fixture'
require Rails.root.join('lib/toybaco/growth/period_end_free_return')
require Rails.root.join('lib/toybaco/growth/retention_selection')
require Rails.root.join('lib/toybaco/growth/purchase_session')
require Rails.root.join('lib/toybaco/growth/purchase_fulfillment')
require Rails.root.join('lib/toybaco/growth/inbox_release')
require Rails.root.join('lib/toybaco/store_fulfillment')
require Rails.root.join('lib/toybaco/subscription_reconciliation/execution')
require Rails.root.join('app/jobs/toybaco/subscription_reconciliation_sweep_job')

FactoryBot.find_definitions unless FactoryBot.factories.registered?(:account)

# A paid growth store whose subscription Stripe ended at its period end, on the real
# database with fixture Stripe, Postiz transport and connection inventory.
class ToybacoGrowthPeriodEndCancelRuntimeTest < ActiveSupport::TestCase
  include FactoryBot::Syntax::Methods
  self.use_transactional_tests = false

  Journal = Toybaco::Growth::RenewalTransition
  Finalizer = Toybaco::Growth::PeriodEndFreeReturn
  InboxHold = Toybaco::Growth::InboxRetention
  PostingHold = Toybaco::Growth::PostingRetention
  FreeRecord = Toybaco::Growth::FreeReturnRecord
  Protocol = Toybaco::Growth::RetentionProtocol
  FLAGS = %w[TOYBACO_GROWTH_FREE_RETURN_ENABLED TOYBACO_POSTING_RETENTION_ENABLED TOYBACO_INBOX_RETENTION_ENABLED].freeze
  NOW = Time.utc(2026, 10, 11, 12)
  STARTED_AT = (NOW - 31.days).to_i
  CANCELED_AT = (NOW - 20.days).to_i
  ENDED_AT = (NOW - 1.hour).to_i

  class Provider
    attr_accessor :sub, :before_read
    attr_reader :reads

    def initialize(sub)
      @sub = sub
      @reads = 0
    end

    def retrieve_subscription(id)
      @reads += 1
      before_read&.call
      raise Toybaco::Checkout::Unavailable, 'unknown subscription' unless id == sub['id']

      Marshal.load(Marshal.dump(sub))
    end
  end

  # The stop receipts Postiz keeps for the store's organization (posting-retention.patch,
  # toybacoApplyPostingRetention): a first stop names no parent; a later one names the
  # current generation and may only narrow its posting accounts and per-account queue.
  # Anything else is the bridge's 403, which the transport reports as an invalid response.
  # A replay of the same transition returns its recorded outcome. old_bridge is the bridge
  # before the parent pair: its fixed key set refuses the pair.
  class PostizHolds
    attr_accessor :old_bridge
    attr_reader :requests, :generations

    def initialize
      @requests = []
      @generations = []
    end

    def call(payload)
      @requests << payload
      raise 'the posting hold must run outside a transaction' if Account.connection.transaction_open?
      raise Protocol::Invalid if old_bridge && payload.key?('previous_transition_id')

      held = @generations.find { |row| row['transition_id'] == payload['transition_id'] } || stop!(payload)
      raise Protocol::Invalid unless held['policy_hash'] == payload['policy_hash']

      { 'version' => 1, 'request_sha256' => Digest::SHA256.hexdigest(JSON.generate(payload)), 'organization_id' => payload['organization_id'],
        'transition_id' => held['transition_id'], 'policy_hash' => held['policy_hash'], 'receipt_hash' => held['receipt_hash'],
        'kept_posts' => 0, 'held_posts' => 0 }
    end

    private

    def stop!(payload)
      current = @generations.last
      raise Protocol::Invalid unless current ? narrows?(payload, current) : !payload.key?('previous_transition_id')
      raise Protocol::Invalid unless Digest::SHA256.hexdigest(JSON.generate(policy(payload))) == payload['policy_hash']

      row = { 'transition_id' => payload['transition_id'], 'policy_hash' => payload['policy_hash'],
              'receipt_hash' => Digest::SHA256.hexdigest("receipt:#{payload['transition_id']}"),
              'keep' => payload['keep_integration_ids'], 'limit' => payload['scheduled_posts_per_account'] }
      @generations << row
      row
    end

    def narrows?(payload, current)
      payload.values_at('previous_transition_id', 'previous_receipt_hash') == current.values_at('transition_id', 'receipt_hash') &&
        (payload['keep_integration_ids'] - current['keep']).empty? && payload['scheduled_posts_per_account'] <= current['limit']
    end

    def policy(payload)
      value = { 'organizationId' => payload['organization_id'], 'transitionId' => payload['transition_id'],
                'keepIntegrationIds' => payload['keep_integration_ids'], 'scheduledPostsPerAccount' => payload['scheduled_posts_per_account'] }
      return value unless payload.key?('previous_transition_id')

      value.merge('previousTransitionId' => payload['previous_transition_id'], 'previousReceiptHash' => payload['previous_receipt_hash'])
    end
  end

  def setup
    @account = create(:account)
    @owner = create(:user, :administrator, account: @account)
    store_contract(Toybaco::Growth::RetentionSnapshot::VERSION)
    @inboxes = 3.times.map { create(:inbox, account: @account) }
    # Free keeps two inboxes: the two oldest, dated here in id order.
    ordered = @inboxes.sort_by { |box| box.id.to_s }
    @kept = ordered.first(2)
    @held = ordered.last
    @rows = { 'inboxes' => ordered.each_with_index.map do |box, index|
      { 'id' => box.id.to_s, 'name' => 'private name', 'created_at_us' => (STARTED_AT * 1_000_000) + index }
    end }
    # Free keeps one posting account by default: the older one, with its queued post.
    @rows['posting_accounts'] = %w[integration_old integration_new].each_with_index.map do |id, index|
      { 'id' => id, 'name' => 'private account', 'created_at_us' => (STARTED_AT * 1_000_000) + index }
    end
    @rows['posts'] = [{ 'id' => 'post_kept', 'integration_id' => 'integration_old', 'publish_at_us' => (NOW + 1.day).to_i * 1_000_000, 'held' => false },
                      { 'id' => 'post_held', 'integration_id' => 'integration_new', 'publish_at_us' => (NOW + 1.day).to_i * 1_000_000, 'held' => false }]
    @inventory = Struct.new(:rows) { def read = rows.deep_dup }.new(@rows)
    @provider = Provider.new(ended_subscription)
    @posting_calls = []
    @transport = lambda do |payload|
      @posting_calls << payload
      flunk 'the posting hold must run outside a transaction' if Account.connection.transaction_open?
      posting_receipt(payload)
    end
  end

  def teardown
    Array(@dispatch_fixtures).each do |operation_id, fact_id, event_id|
      Toybaco::GrowthRenewalCoordinator.where(renewal_operation_id: operation_id).delete_all
      Toybaco::GrowthRenewalDispatch.where(renewal_operation_id: operation_id).delete_all
      Toybaco::RenewalInvoiceFact.where(id: fact_id).delete_all
      Toybaco::RenewalOperation.where(id: operation_id).delete_all
      Toybaco::BillingEvent.where(id: event_id).delete_all
    end
    Toybaco::GrowthPostingExecution.where(account_id: @account.id).delete_all
    Toybaco::SubscriptionSyncRequest.where(id: Array(@sync_receipts)).delete_all
    if @account.persisted?
      # The fixture store never provisioned a Postiz organization.
      @account.reload.update_columns(internal_attributes: @account.internal_attributes.except('postiz'))
      @account.destroy!
    end
    @owner.destroy!
    Current.reset
  end

  # A provisioned paid store, written without callbacks.
  def store_contract(version, addons: [])
    terms = Toybaco::PlanCatalog.default.definition('standard', version)
    @amount = terms.dig('cycles', 'month', 'amount')
    @contract = Toybaco::Entitlements.snapshot_for(terms, cycle: 'month', addons: addons)
                                     .merge('stripe_price_id' => 'price_periodend', 'subscription_item_id' => 'si_periodend')
    attrs = { Toybaco::BillingAccess::OWNER_KEY => @owner.id, 'toybaco_stripe_customer_id' => 'cus_periodend',
              'toybaco_subscription_status' => 'active', 'toybaco_cancel_at_period_end' => true, 'postiz' => { 'enabled' => true } }
    @account.update_columns(internal_attributes: Toybaco::Entitlements.project_attributes(attrs, @contract, subscription_id: 'sub_periodend'))
  end

  def ended_subscription
    price = { 'id' => 'price_periodend', 'currency' => 'jpy', 'unit_amount' => @amount,
              'recurring' => { 'interval' => 'month', 'interval_count' => 1 },
              'product' => { 'metadata' => { 'toybaco_plan' => 'standard', 'toybaco_plan_version' => @contract['plan_version'] } } }
    { 'id' => 'sub_periodend', 'object' => 'subscription', 'customer' => 'cus_periodend', 'livemode' => false,
      'status' => 'canceled', 'cancel_at_period_end' => true, 'collection_method' => 'charge_automatically',
      'canceled_at' => CANCELED_AT, 'cancel_at' => ENDED_AT, 'ended_at' => ENDED_AT,
      'cancellation_details' => { 'comment' => nil, 'feedback' => nil, 'reason' => 'cancellation_requested' },
      'latest_invoice' => { 'id' => 'in_periodend', 'object' => 'invoice', 'status' => 'paid', 'amount_paid' => @amount },
      'items' => { 'object' => 'list', 'has_more' => false, 'data' => [{ 'id' => 'si_periodend', 'quantity' => 1,
                                                                        'current_period_start' => STARTED_AT,
                                                                        'current_period_end' => ENDED_AT, 'price' => price }] } }
  end

  def evidence
    { 'canceled_at' => CANCELED_AT, 'cancel_at' => ENDED_AT, 'ended_at' => ENDED_AT, 'reason' => 'cancellation_requested' }
  end

  def environment(changes = {})
    { 'TOYBACO_STRIPE_MODE' => 'test', 'TOYBACO_POST_URL' => 'https://post.staging.toybaco.jp',
      'FRONTEND_URL' => 'https://app.staging.toybaco.jp', 'TOYBACO_OIDC_CLIENT_SECRET' => 'retention-fixture-secret-with-32-characters' }
      .merge(FLAGS.index_with { 'true' }).merge(changes)
  end

  def posting_receipt(payload)
    { 'version' => 1, 'request_sha256' => Digest::SHA256.hexdigest(JSON.generate(payload)),
      'organization_id' => payload.fetch('organization_id'), 'transition_id' => payload.fetch('transition_id'),
      'policy_hash' => payload.fetch('policy_hash'), 'receipt_hash' => 'b' * 64, 'kept_posts' => 0, 'held_posts' => 0 }
  end

  # The reconciliation opts in to the Free return; opt_in: false calls synchronize like the
  # rake task, child store fulfillment and plan changes do.
  def synchronize(env = environment, opt_in: true)
    options = { subscription_id: 'sub_periodend', client: @provider, environment: env }
    options[:free_return] = true if opt_in
    travel_to(NOW) { Toybaco::StoreFulfillment.synchronize(@account.reload, **options) }
  end

  def finalize(now: NOW, env: environment, transport: @transport)
    Toybaco::Growth::RetentionTransport.stub(:new, ->(**) { transport }) do
      Finalizer.new(@account.reload, client: @provider, environment: env, now: now, inventory: @inventory).call
    end
  end

  def lost_response
    lambda do |payload|
      @posting_calls << payload
      raise Protocol::Invalid
    end
  end

  def free_returns = Toybaco::GrowthFreeReturn.where(account_id: @account.id)
  def grants = Toybaco::GrowthAiGrant.where(account_id: @account.id)

  def test_period_end_cancel_stays_active_through_sync_and_returns_to_free_with_holds
    conversation = create(:conversation, account: @account, inbox: @held)
    message = create(:message, account: @account, inbox: @held, conversation: conversation, content: 'retained period-end body')
    pack = Toybaco::Growth::AiGrants.new(@account).issue!(source: 'pack', source_key: 'pack:periodend', units: 500,
                                                           starts_at: NOW - 1.day, ends_at: NOW + 89.days)
    pack.update!(used: 12)
    channels = @inboxes.map { |box| box.channel.reload.attributes }
    members = @account.account_users.pluck(:id, :user_id, :role)
    statements = []
    subscriber = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] }
    result = nil
    Toybaco::PostizSync.stub(:disable_account!, ->(**) { flunk 'the period-end return keeps Postiz membership and credentials' }) do
      assert_equal 'applied', synchronize
      attrs = @account.reload.internal_attributes
      assert @account.active?
      assert_equal [true, 'canceled', true], [attrs.dig('postiz', 'enabled'), attrs['toybaco_subscription_status'], attrs['toybaco_cancel_at_period_end']]
      refute attrs.key?('toybaco_billing_suspended')
      assert_equal @contract, attrs['toybaco_contract']
      assert Finalizer.applicable?(@account)
      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') { result = finalize }
    end
    assert_equal 'free_completed', result
    receipt = FreeRecord.current(@account.reload)
    journal = receipt.fetch('source_journal')
    assert_equal ['provider_closed', evidence], [journal['state'], journal.dig('binding', 'cancel')]
    refute journal['binding'].key?('failure')
    assert_equal ['free_completed', false], [@account.internal_attributes.dig(Journal::KEY, 'state'), Journal.pending?(@account)]
    assert_equal({ 'state' => 'closed', 'cause' => 'period_end_cancel', 'subscription_id' => 'sub_periodend',
                   'ended_at' => ENDED_AT, 'observed_at' => NOW.to_i }, receipt['settlement'])
    assert_equal [[journal['id'], ['integration_old'], 5]],
                 @posting_calls.map { |payload| payload.values_at('transition_id', 'keep_integration_ids', 'scheduled_posts_per_account') }
    assert_equal [%w[post_kept], %w[post_held]], journal.dig('retention', 'plan', 'posts').values_at('keep', 'hold')
    assert_equal receipt['posting'], @account.internal_attributes[PostingHold::KEY]
    assert_equal [journal['id'], @kept.map { |box| box.id.to_s }], @account.internal_attributes[InboxHold::KEY].values_at('transition_id', 'keep_inbox_ids')
    assert_equal FreeRecord.free_contract, Toybaco::Entitlements.contract_for(@account)
    assert_nil @account.internal_attributes['toybaco_subscription_id']
    assert_equal ['active', true, false], [@account.status, @account.internal_attributes.dig('postiz', 'enabled'),
                                           @account.internal_attributes['toybaco_cancel_at_period_end']]
    assert_equal 1, free_returns.count
    assert_equal [20], grants.where(source: 'included').pluck(:units)
    summary = Toybaco::Growth::AiLedger.new(@account, now: NOW).summary
    assert_equal [508, [20, 500]], [summary['remaining'], summary['grants'].map { |grant| grant['limit'] }]
    assert_raises(InboxHold::Held) { InboxHold.with_inbox(@held, now: NOW) { flunk 'held inbox operated' } }
    assert_equal %i[kept kept], @kept.map { |box| InboxHold.with_inbox(box, now: NOW) { :kept } }
    assert_equal 'retained period-end body', message.reload.content
    assert_equal channels, @inboxes.map { |box| box.channel.reload.attributes }
    assert_equal members, @account.account_users.pluck(:id, :user_id, :role)
    assert_equal [500, 12, NOW + 89.days, nil], [pack.reload.units, pack.used, pack.ends_at, pack.revoked_at]
    free_write = statements.index { |sql| sql.start_with?('INSERT INTO "toybaco_growth_free_returns"') }
    assert_equal 1, statements.drop(free_write).count { |sql| sql.start_with?('UPDATE "accounts"') }
    assert_equal 2, @provider.reads
  end

  def test_completed_return_replays_without_a_provider_read_or_a_second_allowance
    synchronize
    assert_equal 'free_completed', finalize
    receipt = FreeRecord.current(@account.reload)
    @provider.define_singleton_method(:retrieve_subscription) { |*| raise 'a completed return must not read Stripe again' }
    assert_equal 'free_completed', finalize(now: NOW + 2.days)
    assert_equal receipt, FreeRecord.current(@account.reload)
    refute Finalizer.applicable?(@account)
    assert_equal [1, 1, 1], [free_returns.count, grants.where(source: 'included').count, @posting_calls.size]
  end

  def test_lost_posting_response_after_provider_closed_is_pending_and_retries_the_same_transition
    synchronize
    assert_equal 'free_pending', finalize(transport: lost_response)
    journal = @account.reload.internal_attributes.fetch(Journal::KEY)
    assert_equal ['provider_closed', evidence, NOW.to_i], [journal['state'], journal.dig('binding', 'cancel'), journal['observed_at']]
    assert Journal.pending?(@account)
    refute @account.internal_attributes.key?(PostingHold::KEY)
    refute @account.internal_attributes.key?(InboxHold::KEY)
    assert_equal [@contract, 'sub_periodend', 'active'], [@account.internal_attributes['toybaco_contract'],
                                                         @account.internal_attributes['toybaco_subscription_id'], @account.status]
    assert_equal 'free_completed', finalize(now: NOW + 5.minutes)
    receipt = FreeRecord.current(@account.reload)
    assert_equal [journal['id'], (NOW + 5.minutes).to_i], receipt.values_at('transition_id', 'returned_at')
    assert_equal [journal['id']] * 2, @posting_calls.map { |payload| payload['transition_id'] }
    assert_equal 1, free_returns.count
  end

  def test_failure_inside_the_free_write_rolls_it_back_and_the_retry_updates_accounts_once
    synchronize
    issuer = Object.new
    issuer.define_singleton_method(:issue!) { |*| raise 'fixture allowance failure' }
    Toybaco::Growth::AiGrants.stub(:new, issuer) { assert_raises(RuntimeError) { finalize } }
    before = @account.reload.internal_attributes.deep_dup
    assert_equal 'provider_closed', before.dig(Journal::KEY, 'state')
    assert_equal [true, true, false], [PostingHold::KEY, InboxHold::KEY, FreeRecord::KEY].map { |key| before.key?(key) }
    assert_equal [@contract, 'sub_periodend'], before.values_at('toybaco_contract', 'toybaco_subscription_id')
    assert_empty free_returns
    assert_empty grants
    updates = []
    subscriber = ->(_name, _start, _finish, _id, payload) { updates << payload[:sql] if payload[:sql].start_with?('UPDATE "accounts"') }
    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') { assert_equal 'free_completed', finalize }
    assert_equal 1, updates.size
    assert_equal before.dig(Journal::KEY, 'id'), FreeRecord.current(@account.reload)['transition_id']
    assert_equal 'free', Toybaco::Entitlements.contract_for(@account)['plan_id']
  end

  # The Sync keeps its existing suspension, and even a direct Free return writes nothing.
  def assert_existing_suspension_and_no_return(label, sync_env: environment, status: 'suspended', revoked: 1, opt_in: true)
    disabled = []
    revoke = lambda do |**|
      disabled << label
      :not_managed
    end
    Toybaco::PostizSync.stub(:disable_account!, revoke) { assert_equal 'applied', synchronize(sync_env, opt_in: opt_in), label }
    @account.reload
    assert_equal [status, false, revoked], [@account.status, @account.internal_attributes.dig('postiz', 'enabled'), disabled.size], label
    assert_equal 'canceled', @account.internal_attributes['toybaco_subscription_status'], label
    refute Finalizer.applicable?(@account), label
    before = @account.attributes.deep_dup
    assert_equal 'attention', finalize, label
    assert_equal before, @account.reload.attributes, label
    refute @account.internal_attributes.key?(Journal::KEY), label
    assert_equal [0, 0, 0], [@posting_calls.size, free_returns.count, grants.count], label
  end

  def test_old_meter_contract_keeps_the_existing_suspension
    versions = Toybaco::PlanCatalog.default.data.dig('plans', 'standard', 'versions')
    old, = versions.find { |_, terms| terms['legacy'] != true && terms.dig('entitlements', 'ai_meter') != Toybaco::GrowthTerms::METER }
    store_contract(old)
    @provider.sub = ended_subscription
    assert_existing_suspension_and_no_return('old meter')
    assert_equal true, @account.internal_attributes['toybaco_billing_suspended']
  end

  def test_renewal_failure_keeps_the_existing_suspension
    @account.update_columns(internal_attributes: @account.internal_attributes.merge(
      'toybaco_growth_renewal_failure' => { 'subscription_id' => 'sub_periodend', 'invoice_id' => 'in_periodend' }
    ))
    assert_existing_suspension_and_no_return('renewal failure')
  end

  def test_payment_failure_reason_keeps_the_existing_suspension
    @provider.sub['cancellation_details']['reason'] = 'payment_failed'
    assert_existing_suspension_and_no_return('payment_failed')
  end

  def test_immediate_cancel_keeps_the_existing_suspension
    @provider.sub.merge!('cancel_at_period_end' => false, 'cancel_at' => nil)
    assert_existing_suspension_and_no_return('immediate cancel')
  end

  def test_open_latest_invoice_keeps_the_existing_suspension
    @provider.sub['latest_invoice']['status'] = 'open'
    assert_existing_suspension_and_no_return('open invoice')
  end

  def test_admin_suspension_is_kept_without_billing_ownership
    @account.update_columns(status: 'suspended')
    assert_existing_suspension_and_no_return('admin suspended', revoked: 0)
    refute @account.internal_attributes.key?('toybaco_billing_suspended')
  end

  def test_addon_contract_keeps_the_existing_suspension
    manual = Toybaco::Entitlements.new_addon('opt-store', quantity: 1, source: 'manual').merge('account_id' => @account.id + 1_000_000)
    store_contract(Toybaco::Growth::RetentionSnapshot::VERSION, addons: [manual])
    assert_equal 1, @contract['addons'].size
    assert_existing_suspension_and_no_return('addons')
  end

  # A store opened from the sign-up checkout has no purchase record, only its opening request. The
  # period-end return reads neither, completes as before, records no purchase and keeps the request.
  def test_opening_store_without_purchase_record_returns_to_free_at_period_end
    request = Toybaco::OpeningRequest.create!(mode: 'test', session_id: "cs_test_periodend#{SecureRandom.hex(8)}", state: 'account_ready',
                                              deadline_at: NOW, subscription_id: 'sub_periodend', account_id: @account.id, owner_id: @owner.id,
                                              contract_digest: 'c' * 64, account_ready_at: NOW - 31.days)
    refute @account.reload.internal_attributes.key?(Toybaco::Growth::PurchaseIntent::KEY)
    before = request.attributes
    assert_equal 'applied', synchronize
    assert_equal 'free_completed', finalize
    receipt = FreeRecord.current(@account.reload)
    assert_nil receipt['purchase']
    assert_equal [FreeRecord.free_contract, nil], [Toybaco::Entitlements.contract_for(@account), @account.internal_attributes['toybaco_subscription_id']]
    refute @account.internal_attributes.key?(Toybaco::Growth::PurchaseIntent::KEY)
    assert_equal before, request.reload.attributes
    assert_equal 1, free_returns.count
  ensure
    Toybaco::OpeningRequest.where(id: request.id).delete_all if request
  end

  # The earlier growth version has the growth meter, but the retention snapshot and the Free return
  # are defined for the current terms only: it keeps the existing suspension and never starts a return.
  def test_previous_growth_version_keeps_the_existing_suspension
    store_contract('2026-09-18.1')
    assert_equal Toybaco::GrowthTerms::METER, @contract.dig('entitlements', 'ai_meter')
    refute_equal Toybaco::GrowthTerms::VERSION, @contract['plan_version']
    @provider.sub = ended_subscription
    assert_existing_suspension_and_no_return('previous growth version')
    assert_equal true, @account.internal_attributes['toybaco_billing_suspended']
  end

  def test_direct_synchronize_without_the_reconciliation_opt_in_keeps_the_existing_suspension
    assert_existing_suspension_and_no_return('no opt-in with all rollout flags', opt_in: false)
    assert_equal true, @account.internal_attributes['toybaco_billing_suspended']
  end

  # Each rollout flag alone keeps the existing suspension when it is closed.
  FLAGS.each do |flag|
    define_method("test_closed_#{flag.downcase}_keeps_the_existing_suspension") do
      assert_existing_suspension_and_no_return("#{flag} unset", sync_env: environment.except(flag))
      assert_equal true, @account.internal_attributes['toybaco_billing_suspended']
    end
  end

  def test_revoked_cancellation_keeps_the_paid_store_and_writes_no_journal
    @provider.sub.merge!('status' => 'active', 'cancel_at_period_end' => false, 'canceled_at' => nil, 'cancel_at' => nil,
                         'ended_at' => nil, 'cancellation_details' => { 'comment' => nil, 'feedback' => nil, 'reason' => nil })
    assert_equal 'applied', synchronize
    @account.reload
    assert_equal ['active', 'active', false, true], [@account.status, *@account.internal_attributes.values_at(
      'toybaco_subscription_status', 'toybaco_cancel_at_period_end'
    ), @account.internal_attributes.dig('postiz', 'enabled')]
    refute Finalizer.applicable?(@account)
    before = @account.attributes.deep_dup
    assert_equal 'attention', finalize
    assert_equal before, @account.reload.attributes
    refute @account.internal_attributes.key?(Journal::KEY)
    assert_empty @posting_calls
  end

  def test_missing_rollout_flag_needs_attention_before_any_read_or_write
    synchronize
    reads = @provider.reads
    before = @account.reload.attributes.deep_dup
    FLAGS.each do |flag|
      [environment.except(flag), environment(flag => 'false'), environment(flag => '1')].each do |env|
        assert_equal 'attention', finalize(env: env), "#{flag}=#{env[flag].inspect}"
      end
    end
    assert_equal [before, reads, []], [@account.reload.attributes, @provider.reads, @posting_calls]
    assert Finalizer.applicable?(@account)
    assert_equal 'free_completed', finalize
  end

  def test_tampered_cancel_binding_needs_attention_and_is_never_advanced
    synchronize
    assert_equal 'free_pending', finalize(transport: lost_response)
    original = @account.reload.internal_attributes.deep_dup
    journal = original.fetch(Journal::KEY)
    rebound = lambda do |binding|
      value = journal.merge('binding' => binding)
      value.merge('id' => Journal.identity(value))
    end
    {
      unsigned_end: journal.deep_merge('binding' => { 'cancel' => { 'ended_at' => ENDED_AT + 1 } }),
      text_end: rebound.call(journal['binding'].deep_merge('cancel' => { 'ended_at' => ENDED_AT.to_s })),
      missing_reason: rebound.call(journal['binding'].merge('cancel' => evidence.except('reason'))),
      other_subscription: rebound.call(journal['binding'].merge('subscription_id' => 'sub_other')),
      failure_added: rebound.call(journal['binding'].merge('failure' => {}))
    }.each do |label, value|
      @account.update_columns(internal_attributes: original.merge(Journal::KEY => value))
      assert_equal 'attention', finalize, label.to_s
      attrs = @account.reload.internal_attributes
      assert_equal value, attrs[Journal::KEY], label.to_s
      assert_equal [false, false, 0], [attrs.key?(PostingHold::KEY), attrs.key?(InboxHold::KEY), free_returns.count], label.to_s
    end
  end

  def test_pending_period_end_journal_blocks_the_owner_retention_selection
    synchronize
    selection = Toybaco::Growth::RetentionSelection.new(@account.reload, @owner, target: 'free', inventory: @inventory)
    revision = selection.read.fetch('revision')
    assert_equal 'free_pending', finalize(transport: lost_response)
    assert Journal.pending?(@account.reload)
    assert_raises(Toybaco::Growth::RetentionSelection::Changed) do
      selection.save!(selected: { 'inboxes' => [@held.id.to_s], 'posting_accounts' => [] }, revision: revision)
    end
    refute @account.reload.internal_attributes.key?(Toybaco::Growth::RetentionSelection::KEY)
  end

  def test_unresolved_posting_execution_defers_before_any_write
    synchronize
    execution = Toybaco::GrowthPostingExecution.create!(account_id: @account.id, operation_id: 'a' * 64, identity_hash: 'b' * 64,
                                                        request: { 'version' => 2 }, request_hash: 'c' * 64, state: 'prepared',
                                                        created_at: NOW, updated_at: NOW)
    before = @account.reload.attributes.deep_dup
    assert_equal 'free_pending', finalize
    assert_equal [before, [], 0], [@account.reload.attributes, @posting_calls, free_returns.count]
    execution.update!(state: 'cancelled', terminal_at: NOW, updated_at: NOW)
    assert_equal 'free_completed', finalize
  end

  def test_live_automatic_lease_defers_before_any_write_and_is_not_consumed
    synchronize
    grant = Toybaco::Growth::AiGrants.new(@account).issue!(source: 'included', source_key: 'paid:sub_periodend:fixture:base',
                                                            units: 500, starts_at: NOW - 1.day, ends_at: NOW + 20.days)
    operation = Toybaco::GrowthAiOperation.create!(account: @account, grant: grant, request_key: 'a' * 64, context_digest: 'b' * 64,
                                                   token_digest: 'c' * 64, kind: 'automatic_reply', lease_expires_at: NOW + 300)
    before = @account.reload.attributes.deep_dup
    assert_equal 'free_pending', finalize
    assert_equal [before, [], 0], [@account.reload.attributes, @posting_calls, free_returns.count]
    assert_equal 'free_completed', finalize(now: NOW + 301)
    assert_equal [NOW + 300, 'reserved', 0], [operation.reload.lease_expires_at, operation.state, grant.reload.used]
  end

  def accept_sync(at: NOW, subscription: 'sub_periodend')
    record = Toybaco::SubscriptionReconciliationJob.stub(:perform_later, ->(*) { true }) do
      Toybaco::SubscriptionReconciliation.request!(subscription, mode: 'test', now: at)
    end
    (@sync_receipts ||= []) << record.id
    record
  end

  def execute_sync(record, at: NOW, transport: @transport, execution: Toybaco::SubscriptionReconciliation::Execution)
    Toybaco::Growth::RetentionTransport.stub(:new, ->(**) { transport }) do
      Toybaco::Growth::RetentionInventory.stub(:new, ->(*) { @inventory }) do
        travel_to(at) do
          execution.new(record, client: @provider, now: at, environment: environment).call
        end
      end
    end
  end

  def test_reconciliation_request_completes_and_returns_the_store_to_free
    record = accept_sync
    assert_equal 'completed', execute_sync(record)
    assert_equal ['completed', 'applied', 1], [record.reload.state, record.result, record.completed_revision]
    assert_equal ['free', 'active'], [Toybaco::Entitlements.contract_for(@account.reload)['plan_id'], @account.status]
    assert_equal 1, free_returns.count
    later = accept_sync(at: NOW + 1.minute)
    assert_equal 'superseded', execute_sync(later, at: NOW + 1.minute)
    assert_equal [1, 1], [free_returns.count, @posting_calls.size]
  end

  def test_reconciliation_request_waits_for_a_pending_free_return_and_retries_it
    record = accept_sync
    assert_equal 'pending', execute_sync(record, transport: lost_response)
    assert_equal ['pending', 'free_return_pending', 1, NOW + 30], [record.reload.state, record.result, record.attempts, record.next_attempt_at]
    journal = @account.reload.internal_attributes.fetch(Journal::KEY)
    assert_equal ['provider_closed', 'active', @contract], [journal['state'], @account.status, @account.internal_attributes['toybaco_contract']]
    assert_equal 'completed', execute_sync(record, at: NOW + 30)
    assert_equal ['completed', 'applied', 2], [record.reload.state, record.result, record.attempts]
    assert_equal journal['id'], FreeRecord.current(@account.reload)['transition_id']
    assert_equal [journal['id']] * 2, @posting_calls.map { |payload| payload['transition_id'] }
  end

  # A second cycle: the store returned to Free, bought again and cancelled again.
  REPURCHASED_AT = NOW + 1.day

  def return_first_cycle(holds)
    assert_equal 'applied', synchronize
    assert_equal 'free_completed', finalize(transport: holds)
    FreeRecord.current(@account.reload)
  end

  # The owner buys again through the real checkout session and fulfilment (Stripe is the
  # shared purchase fixture) and cancels at the period end right after buying.
  def repurchase!
    @stripe = ToybacoGrowthPurchaseStripeFixture.new(Toybaco::PlanCatalog.default)
    selection = { 'plan_id' => 'standard', 'plan_version' => Toybaco::Growth::RetentionSnapshot::VERSION, 'cycle' => 'month' }
    checkout = { 'TOYBACO_DEPLOYMENT_ENVIRONMENT' => 'staging', 'TOYBACO_STRIPE_MODE' => 'test' }
    travel_to(REPURCHASED_AT) do
      Toybaco::Growth::PurchaseSession.new(@account.reload, @owner, client: @stripe, environment: checkout).start!(selection)
      session = Toybaco::Growth::PurchaseIntent.saved(@account.reload).fetch('session_id')
      @second_sub = @stripe.pay!(session)
      @stripe.subscriptions[@second_sub]['cancel_at_period_end'] = true
      assert_equal 'complete', Toybaco::Growth::PurchaseFulfillment.new(client: @stripe).complete!(session)
    end
    @second_end = @stripe.subscriptions.fetch(@second_sub).dig('items', 'data', 0, 'current_period_end')
    @account.reload
  end

  def second_at = Time.at(@second_end).utc + 1.hour

  def second_evidence
    { 'canceled_at' => REPURCHASED_AT.to_i + 60, 'cancel_at' => @second_end, 'ended_at' => @second_end, 'reason' => 'cancellation_requested' }
  end

  # Stripe ends the new subscription at its period end; the held post of the first
  # generation is a held draft in the inventory by then.
  def end_second_subscription
    @provider.sub = @stripe.subscriptions.fetch(@second_sub).deep_dup.merge(
      'object' => 'subscription', 'status' => 'canceled', 'collection_method' => 'charge_automatically',
      'cancellation_details' => { 'comment' => nil, 'feedback' => nil, 'reason' => 'cancellation_requested' }
    ).merge(second_evidence.except('reason'))
  end

  def synchronize_second
    end_second_subscription
    @rows['posts'].last['held'] = true
    travel_to(second_at) do
      Toybaco::StoreFulfillment.synchronize(@account.reload, subscription_id: @second_sub, client: @provider, environment: environment,
                                                             free_return: true)
    end
  end

  def finalize_second(holds)
    travel_to(second_at) { finalize(now: second_at, transport: holds) }
  end

  def test_second_period_end_cancel_after_a_repurchase_returns_to_free_with_next_generation_holds
    holds = PostizHolds.new
    first = return_first_cycle(holds)
    first_row = free_returns.sole.attributes
    first_ack = @account.internal_attributes[PostingHold::KEY]
    repurchase!
    assert_equal ['standard', @second_sub, 'active', true], [Toybaco::Entitlements.contract_for(@account)['plan_id'],
                                                             *@account.internal_attributes.values_at('toybaco_subscription_id', 'toybaco_subscription_status',
                                                                                                     'toybaco_cancel_at_period_end')]
    # The purchase itself changes no journal, acknowledgement, hold or return pointer.
    assert_equal first['source_journal'].merge('state' => 'free_completed', 'observed_at' => first['returned_at']),
                 @account.internal_attributes[Journal::KEY]
    assert_equal [first_ack, first['inbox'], FreeRecord.reference(first)],
                 @account.internal_attributes.values_at(PostingHold::KEY, InboxHold::KEY, FreeRecord::KEY)
    Toybaco::PostizSync.stub(:disable_account!, ->(**) { flunk 'the second return keeps Postiz membership and credentials' }) do
      assert_equal 'applied', synchronize_second
    end
    attrs = @account.reload.internal_attributes
    assert_equal ['active', true, 'canceled', true], [@account.status, attrs.dig('postiz', 'enabled'), attrs['toybaco_subscription_status'],
                                                      attrs['toybaco_cancel_at_period_end']]
    assert_equal false, attrs['toybaco_billing_suspended'], 'the first return cleared the flag and this Sync does not suspend'
    assert Finalizer.applicable?(@account)
    assert_equal 'free_completed', finalize_second(holds)
    second = FreeRecord.current(@account.reload)
    journal = second.fetch('source_journal')
    refute_equal first['transition_id'], second['transition_id']
    assert_equal [journal['id'], 'provider_closed', @second_sub, second_evidence],
                 [second['transition_id'], journal['state'], journal.dig('binding', 'subscription_id'), journal.dig('binding', 'cancel')]
    # Generation 2 names the returned hold and only narrows it.
    request = holds.requests.last
    assert_equal [journal['id'], first['transition_id'], first_ack['receipt_hash'], ['integration_old'], 5],
                 request.values_at('transition_id', 'previous_transition_id', 'previous_receipt_hash', 'keep_integration_ids',
                                   'scheduled_posts_per_account')
    assert_equal %w[previous_transition_id previous_receipt_hash], request.keys.last(2)
    policy = { 'organizationId' => request['organization_id'], 'transitionId' => journal['id'], 'keepIntegrationIds' => ['integration_old'],
               'scheduledPostsPerAccount' => 5, 'previousTransitionId' => first['transition_id'], 'previousReceiptHash' => first_ack['receipt_hash'] }
    assert_equal Digest::SHA256.hexdigest(JSON.generate(policy)), request['policy_hash']
    assert_equal [2, [first['transition_id'], journal['id']]], [holds.generations.size, holds.generations.pluck('transition_id')]
    # Its acknowledgement and inbox hold replace the returned ones, which stay in the first sale.
    ack = @account.internal_attributes[PostingHold::KEY]
    assert_equal [journal['id'], holds.generations.last['receipt_hash']], ack.values_at('transition_id', 'receipt_hash')
    assert_equal [ack, @account.internal_attributes[InboxHold::KEY]], second.values_at('posting', 'inbox')
    assert_equal [journal['id'], ack['receipt_hash'], @kept.map { |box| box.id.to_s }],
                 second['inbox'].values_at('transition_id', 'posting_receipt_hash', 'keep_inbox_ids')
    assert_equal [2, first_row], [free_returns.count, free_returns.order(:id).first.attributes]
    assert_equal [first_ack, first['inbox']], free_returns.order(:id).first.receipt.values_at('posting', 'inbox')
    # The new sale is archived with its purchase, and the store is Free on the new return's allowance.
    assert_equal [@second_sub, 'complete'], second['purchase'].values_at('subscription_id', 'state')
    assert_equal FreeRecord.free_contract, Toybaco::Entitlements.contract_for(@account)
    assert_equal ['active', 'free_completed', nil], [@account.status, @account.internal_attributes.dig(Journal::KEY, 'state'),
                                                     @account.internal_attributes['toybaco_subscription_id']]
    refute @account.internal_attributes.key?(Toybaco::Growth::PurchaseIntent::KEY)
    refute Journal.pending?(@account)
    refute Finalizer.applicable?(@account)
    latest = grants.where(source: 'included').order(:id).last
    assert_equal [true, 20], [latest.source_key.start_with?(FreeRecord.free_prefix(second)), latest.units]
    assert_raises(InboxHold::Held) { InboxHold.with_inbox(@held, now: second_at) { flunk 'held inbox operated' } }
    assert_equal %i[kept kept], @kept.map { |box| InboxHold.with_inbox(box, now: second_at) { :kept } }
  end

  # The first return kept the newer posting account by the owner's choice. After the new
  # purchase that choice belongs to the old subscription, so the second return takes the
  # default, which stays within the returned hold (Postiz only narrows it) and completes.
  def test_second_return_without_a_new_choice_keeps_the_posting_account_of_the_returned_hold
    holds = PostizHolds.new
    assert_equal 'applied', synchronize
    selection = Toybaco::Growth::RetentionSelection.new(@account.reload, @owner, target: 'free', inventory: @inventory)
    selection.save!(selected: { 'inboxes' => @kept.map { |box| box.id.to_s }, 'posting_accounts' => ['integration_new'] },
                    revision: selection.read.fetch('revision'))
    assert_equal 'free_completed', finalize(transport: holds)
    first = FreeRecord.current(@account.reload)
    assert_equal [%w[integration_new], %w[integration_old]], first.dig('source_journal', 'retention', 'plan', 'posting_accounts').values_at('keep', 'hold')
    assert_equal %w[integration_new], holds.generations.first['keep']
    repurchase!
    assert_equal 'applied', synchronize_second
    assert_equal 'free_completed', finalize_second(holds)
    second = FreeRecord.current(@account.reload)
    assert_equal [%w[integration_new], %w[integration_old]], second.dig('source_journal', 'retention', 'plan', 'posting_accounts').values_at('keep', 'hold')
    assert_equal [%w[integration_new], first['transition_id']], holds.requests.last.values_at('keep_integration_ids', 'previous_transition_id')
    assert_equal [2, 2], [holds.generations.size, free_returns.count]
  end

  # After the new purchase the owner resumes the inbox the first return held, within the paid limit.
  def resume_held_inbox!
    at = REPURCHASED_AT + 1.hour
    service = Toybaco::Growth::InboxRelease.new(@account.reload, @owner, client: @stripe,
                                                                         environment: environment('TOYBACO_INBOX_RELEASE_ENABLED' => 'true'), now: at)
    travel_to(at) { service.call(inbox_ids: [@held.id.to_s], revision: service.read.fetch('revision'), request_id: 'a' * 64) }
  end

  # A remaining transient: while Postiz refuses the next generation (the previous bridge, an
  # outage or an exhausted retry), an inbox the owner resumed after the new purchase stays
  # usable above the Free limit. Nothing suspends the store or holds that inbox until the
  # return completes; a permanent stop at the cancellation is a separate slice.
  def test_resumed_inbox_stays_usable_above_the_free_limit_while_the_second_return_waits_for_postiz
    holds = PostizHolds.new
    first = return_first_cycle(holds)
    repurchase!
    released = resume_held_inbox!
    assert_equal :usable, InboxHold.with_inbox(@held, now: REPURCHASED_AT + 1.hour) { :usable }
    assert_equal 'applied', synchronize_second
    holds.old_bridge = true
    assert_equal 'free_pending', finalize_second(holds)
    attrs = @account.reload.internal_attributes
    assert_equal ['active', true, false, 'standard', @second_sub],
                 [@account.status, attrs.dig('postiz', 'enabled'), attrs['toybaco_billing_suspended'],
                  Toybaco::Entitlements.contract_for(@account)['plan_id'], attrs['toybaco_subscription_id']]
    assert_equal ['provider_closed', first['inbox'], Toybaco::Growth::InboxReleaseRecord.reference(released)],
                 [attrs.dig(Journal::KEY, 'state'), attrs[InboxHold::KEY], attrs[Toybaco::Growth::InboxReleaseRecord::KEY]]
    limit = FreeRecord.free_contract.dig('entitlements', 'limits', 'inboxes')
    usable = @inboxes.select { |box| InboxHold.with_inbox(box, now: second_at) { true } }
    assert_equal [2, 3], [limit, usable.size]
    holds.old_bridge = false
    assert_equal 'free_completed', finalize_second(holds)
    refute @account.reload.internal_attributes.key?(Toybaco::Growth::InboxReleaseRecord::KEY)
    assert_raises(InboxHold::Held) { InboxHold.with_inbox(@held, now: second_at) { flunk 'held inbox operated' } }
  end

  def test_journal_rule_starts_a_new_cycle_only_after_the_completed_return_of_an_earlier_subscription
    rules = Toybaco::Growth::PeriodEndCancel
    completed = { 'state' => 'free_completed', 'binding' => { 'subscription_id' => 'sub_first', 'cancel' => evidence } }
    unfinished = completed.merge('state' => 'provider_closed', 'binding' => completed['binding'].merge('subscription_id' => 'sub_second'))
    attrs = ->(journal, current = 'sub_second') { { 'toybaco_subscription_id' => current, Journal::KEY => journal } }
    assert rules.journal?('toybaco_subscription_id' => 'sub_second'), 'no journal'
    assert rules.journal?(attrs.call(completed)), 'the completed return of an earlier subscription'
    failure = completed.merge('binding' => completed['binding'].except('cancel').merge('failure' => {}))
    assert rules.journal?(attrs.call(failure)), 'an earlier return after a renewal failure'
    refute rules.journal?(attrs.call(completed, 'sub_first')), 'this subscription already returned'
    ['sub-first', 'sub_', "sub_first\n", 'cus_first', nil, 42].each do |bound|
      refute rules.journal?(attrs.call(completed.deep_merge('binding' => { 'subscription_id' => bound }))), "bound #{bound.inspect}"
    end
    ['sub_bad!', '', nil].each { |current| refute rules.journal?(attrs.call(completed, current)), "current #{current.inspect}" }
    assert rules.journal?(attrs.call(unfinished)), 'the unfinished cancel journal of this subscription'
    assert rules.journal?(attrs.call(unfinished.merge('state' => 'prepared'))), 'a prepared cancel journal of this subscription'
    refute rules.journal?(attrs.call(unfinished, 'sub_third')), 'the unfinished journal of another subscription'
    %w[invoice_voided payment_recovered].each { |state| refute rules.journal?(attrs.call(unfinished.merge('state' => state))), state }
    refute rules.journal?(attrs.call(unfinished.merge('binding' => unfinished['binding'].except('cancel')))), 'an unfinished failure journal'
    [nil, 'free_completed', completed.merge('binding' => 'sub_first')].each { |journal| refute rules.journal?(attrs.call(journal)), journal.inspect }
  end

  def test_second_return_that_would_widen_the_returned_posting_hold_stops_before_http
    holds = PostizHolds.new
    first = return_first_cycle(holds)
    repurchase!
    assert_equal 'applied', synchronize_second
    # The owner keeps the posting account that the returned hold stopped.
    selection = Toybaco::Growth::RetentionSelection.new(@account.reload, @owner, target: 'free', inventory: @inventory)
    selection.save!(selected: { 'inboxes' => @kept.map { |box| box.id.to_s }, 'posting_accounts' => ['integration_new'] },
                    revision: selection.read.fetch('revision'))
    assert_equal 'attention', finalize_second(holds)
    attrs = @account.reload.internal_attributes
    journal = attrs.fetch(Journal::KEY)
    assert_equal ['provider_closed', @second_sub, ['integration_new']],
                 [journal['state'], journal.dig('binding', 'subscription_id'), journal.dig('retention', 'selected', 'posting_accounts')]
    assert_raises(Journal::Changed) do
      travel_to(second_at) { PostingHold.new(@account, environment: environment, transport: holds, clock: -> { second_at }).call }
    end
    assert_equal [1, 1], [holds.requests.size, holds.generations.size]
    assert_equal [first['posting'], first['inbox'], FreeRecord.reference(first)],
                 @account.reload.internal_attributes.values_at(PostingHold::KEY, InboxHold::KEY, FreeRecord::KEY)
    assert_equal [1, @second_sub, 'standard'], [free_returns.count, @account.internal_attributes['toybaco_subscription_id'],
                                                Toybaco::Entitlements.contract_for(@account)['plan_id']]
    assert Journal.pending?(@account)
  end

  # The narrowing rule itself. A Free receipt only validates against the current Free
  # definition, so a larger per-account queue cannot arise between two valid returns of
  # one version; the rule still refuses it, and malformed returned values, before HTTP.
  def test_next_generation_may_only_narrow_the_returned_posting_accounts_and_queue_limit
    service = PostingHold.new(@account, environment: environment)
    returned = lambda do |keep, limit|
      { 'source_journal' => { 'retention' => { 'selected' => { 'posting_accounts' => keep },
                                               'target' => { 'entitlements' => { 'limits' => { 'scheduled_posts_per_account' => limit } } } } } }
    end
    narrowed = ->(keep, limit, value) { service.send(:narrowed!, keep, { 'scheduled_posts_per_account' => limit }, value) }
    assert_nil narrowed.call(['integration_old'], 5, returned.call(%w[integration_new integration_old], 5))
    assert_nil narrowed.call([], 0, returned.call(['integration_old'], 5))
    [[['integration_new'], 5, returned.call(['integration_old'], 5)], [['integration_old'], 6, returned.call(['integration_old'], 5)],
     [['integration_old'], 5, returned.call(nil, 5)], [['integration_old'], 5, returned.call(['integration_old'], '5')],
     [['integration_old'], 5, returned.call(%w[integration_old integration_old], 5)], [['integration_old'], 5, {}]].each do |keep, limit, value|
      assert_raises(Journal::Changed, [keep, limit, value].inspect) { narrowed.call(keep, limit, value) }
    end
  end

  # A missing or changed record of the first return needs attention before the provider
  # read and writes nothing: the new subscription waits for an operator.
  def test_second_return_with_a_missing_or_changed_completed_record_needs_attention_and_writes_nothing
    holds = PostizHolds.new
    first = return_first_cycle(holds)
    repurchase!
    assert_equal 'applied', synchronize_second
    pristine = [@account.reload.internal_attributes.deep_dup, free_returns.sole.receipt.deep_dup]
    {
      missing_pointer: -> { @account.update_columns(internal_attributes: pristine.first.except(FreeRecord::KEY)) },
      moved_pointer: lambda do
        @account.update_columns(internal_attributes: pristine.first.deep_merge(FreeRecord::KEY => { 'returned_at' => first['returned_at'] + 1 }))
      end,
      changed_receipt: -> { free_returns.update_all(receipt: pristine.last.merge('returned_at' => first['returned_at'] + 1)) },
      missing_row: -> { free_returns.delete_all }
    }.each do |label, tamper|
      tamper.call
      before = [@account.reload.attributes.deep_dup, free_returns.map(&:attributes), grants.count, holds.requests.size, @provider.reads]
      assert_equal 'attention', finalize_second(holds), label.to_s
      assert_equal before, [@account.reload.attributes, free_returns.map(&:attributes), grants.count, holds.requests.size, @provider.reads],
                   label.to_s
      @account.update_columns(internal_attributes: pristine.first)
      free_returns.update_all(receipt: pristine.last)
    end
  end

  # The record changes during the provider read while a posting execution is unresolved:
  # the journal write checks the record first, so the change needs attention instead of a
  # retry, and nothing is written.
  def test_completed_record_changed_during_the_provider_read_needs_attention_before_busy_work
    holds = PostizHolds.new
    first = return_first_cycle(holds)
    repurchase!
    assert_equal 'applied', synchronize_second
    Toybaco::GrowthPostingExecution.create!(account_id: @account.id, operation_id: 'a' * 64, identity_hash: 'b' * 64,
                                            request: { 'version' => 2 }, request_hash: 'c' * 64, state: 'prepared',
                                            created_at: second_at, updated_at: second_at)
    detached = @account.reload.internal_attributes.except(FreeRecord::KEY)
    @provider.before_read = -> { @account.update_columns(internal_attributes: detached) }
    assert_equal 'attention', finalize_second(holds)
    assert_equal detached, @account.reload.internal_attributes
    assert_equal [1, [first['transition_id']]], [holds.requests.size, free_returns.pluck(:transition_id)]
  end

  # Until Postiz accepts the parent pair, its bridge refuses the next generation (403): the
  # return stays pending with its journal and no new acknowledgement, and completes on a
  # retry after the Postiz image is deployed.
  def test_second_return_against_the_previous_postiz_bridge_stays_pending_and_completes_after_its_deploy
    holds = PostizHolds.new
    first = return_first_cycle(holds)
    repurchase!
    assert_equal 'applied', synchronize_second
    holds.old_bridge = true
    assert_equal 'free_pending', finalize_second(holds)
    attrs = @account.reload.internal_attributes
    assert_equal ['provider_closed', @second_sub], [attrs.dig(Journal::KEY, 'state'), attrs.dig(Journal::KEY, 'binding', 'subscription_id')]
    assert_equal [first['posting'], first['inbox'], 1], [attrs[PostingHold::KEY], attrs[InboxHold::KEY], free_returns.count]
    holds.old_bridge = false
    assert_equal 'free_completed', finalize_second(holds)
    assert_equal [2, attrs.dig(Journal::KEY, 'id')], [free_returns.count, FreeRecord.current(@account.reload)['transition_id']]
  end

  # The documented operator re-arm of a request that ended in attention.
  def rearm!(record, at)
    record.with_lock do
      record.update!(Toybaco::SubscriptionReconciliation.rearm_values(at).merge(requested_revision: record.requested_revision + 1))
    end
  end

  # While Postiz refuses the next generation, the reconciliation retries the return and the
  # store stays active (the resumed inbox above the Free limit). When the retries end in
  # attention, that run suspends the store as before (fail-closed) and writes nothing of the
  # return. After the Postiz deploy an operator re-arms the request: the return continues
  # from the suspension and lifts it when it completes.
  def test_free_return_retries_ending_in_attention_suspend_the_store_until_a_rearmed_return_completes
    holds = PostizHolds.new
    first = return_first_cycle(holds)
    repurchase!
    resume_held_inbox!
    holds.old_bridge = true
    end_second_subscription
    record = accept_sync(at: second_at, subscription: @second_sub)
    disabled = []
    at = second_at
    states = []
    Toybaco::PostizSync.stub(:disable_account!, lambda { |**|
      disabled << :disabled
      :not_managed
    }) do
      until record.reload.state == 'attention'
        states << [execute_sync(record, at: at, transport: holds), @account.reload.status]
        at = record.reload.next_attempt_at
      end
    end
    assert_equal [Toybaco::SubscriptionReconciliation::ATTEMPTS, 'free_return_pending'], [record.attempts, record.result]
    assert_equal [['pending', 'active']] * (Toybaco::SubscriptionReconciliation::ATTEMPTS - 1) + [%w[attention suspended]], states
    assert_operator at - second_at, :<, 12.hours
    attrs = @account.reload.internal_attributes
    assert_equal ['suspended', true, false, 1], [@account.status, attrs['toybaco_billing_suspended'], attrs.dig('postiz', 'enabled'), disabled.size]
    journal = attrs.fetch(Journal::KEY)
    assert_equal ['provider_closed', @second_sub, second_at.to_i], [journal['state'], journal.dig('binding', 'subscription_id'), journal['prepared_at']]
    assert_equal [first['posting'], first['inbox'], 1], [attrs[PostingHold::KEY], attrs[InboxHold::KEY], free_returns.count]
    # The suspension revokes the resumed inbox with the existing contract boundary; lifting
    # the suspension later never restores that release.
    refute attrs.key?(Toybaco::Growth::InboxReleaseRecord::KEY)
    assert_equal [1 + Toybaco::SubscriptionReconciliation::ATTEMPTS, 1], [holds.requests.size, holds.generations.size]
    assert Finalizer.applicable?(@account), 'the return may continue from its own suspension'
    holds.old_bridge = false
    rearm!(record, at)
    assert_equal 'completed', execute_sync(record, at: at, transport: holds)
    assert_equal %w[completed applied], [record.reload.state, record.result]
    second = FreeRecord.current(@account.reload)
    attrs = @account.internal_attributes
    assert_equal [journal['id'], 2, 'free_completed'], [second['transition_id'], free_returns.count, attrs.dig(Journal::KEY, 'state')]
    # The Free contract enables posting again; the Postiz membership follows on the next
    # posting sign-in (the existing sync prefers a temporary denial over an early grant).
    assert_equal ['active', false, true], [@account.status, attrs['toybaco_billing_suspended'], attrs.dig('postiz', 'enabled')]
    assert_equal FreeRecord.free_contract, Toybaco::Entitlements.contract_for(@account)
    refute attrs.key?(Toybaco::Growth::InboxReleaseRecord::KEY)
    assert_raises(InboxHold::Held) { InboxHold.with_inbox(@held, now: at) { flunk 'held inbox operated' } }
    assert_equal 2, holds.generations.size
  end

  # One tick of the reconciliation sweep. The jobs it enqueues run inline as the job would,
  # with the fixture Stripe and Postiz transport; returns the request ids it enqueued.
  def sweep!(at, transport:)
    enqueued = []
    job = lambda do |id|
      enqueued << id
      Toybaco::SubscriptionReconciliation::Execution.new(Toybaco::SubscriptionSyncRequest.find(id), client: @provider, now: at,
                                                                                                environment: environment).call
      true
    end
    Toybaco::Growth::RetentionTransport.stub(:new, ->(**) { transport }) do
      Toybaco::Growth::RetentionInventory.stub(:new, ->(*) { @inventory }) do
        Toybaco::SubscriptionReconciliationJob.stub(:perform_later, job) do
          Toybaco::PostizSync.stub(:disable_account!, ->(**) { :not_managed }) do
            travel_to(at) { Toybaco::SubscriptionReconciliationSweepJob.perform_now }
          end
        end
      end
    end
    enqueued
  end

  def second_request_against_the_previous_bridge(resume: false)
    holds = PostizHolds.new
    return_first_cycle(holds)
    repurchase!
    resume_held_inbox! if resume
    holds.old_bridge = true
    end_second_subscription
    [holds, accept_sync(at: second_at, subscription: @second_sub)]
  end

  # 47 free_return_pending attempts; returns the slot of the last one.
  def exhaust_but_last!(record, holds)
    at = second_at
    (Toybaco::SubscriptionReconciliation::ATTEMPTS - 1).times do
      assert_equal 'pending', execute_sync(record, at: at, transport: holds)
      at = record.reload.next_attempt_at
    end
    at
  end

  # (a) The attention run's suspension Sync fails: the request ends in attention with the store
  # still active and the resumed inbox usable. The next sweep retries the suspension until it
  # commits; a suspended store is no longer a target. (d) After the Postiz deploy and a re-arm
  # the request is due again and not a suspension target: the return completes from there.
  def test_attention_suspension_that_fails_in_its_run_is_retried_by_the_sweep
    holds, record = second_request_against_the_previous_bridge(resume: true)
    at = exhaust_but_last!(record, holds)
    synchronize = Toybaco::StoreFulfillment.method(:synchronize)
    failing = lambda do |account, **options|
      raise Toybaco::Checkout::Error, 'fixture outage' unless options[:free_return]

      synchronize.call(account, **options)
    end
    Toybaco::StoreFulfillment.stub(:synchronize, failing) { assert_equal 'attention', execute_sync(record, at: at, transport: holds) }
    assert_equal %w[attention free_return_pending active], [record.reload.state, record.result, @account.reload.status]
    assert_equal :usable, InboxHold.with_inbox(@held, now: at) { :usable }
    assert Toybaco::SubscriptionReconciliation.suspension_due?(record)
    assert_equal [record.id], sweep!(at + 60, transport: holds)
    attrs = @account.reload.internal_attributes
    assert_equal ['suspended', true, 'provider_closed'], [@account.status, attrs['toybaco_billing_suspended'], attrs.dig(Journal::KEY, 'state')]
    refute attrs.key?(Toybaco::Growth::InboxReleaseRecord::KEY)
    assert_equal [false, [], 1], [Toybaco::SubscriptionReconciliation.suspension_due?(record), sweep!(at + 180, transport: holds), free_returns.count]
    holds.old_bridge = false
    rearm!(record, at + 240)
    refute Toybaco::SubscriptionReconciliation.suspension_due?(record.reload)
    assert_equal [record.id], sweep!(at + 240, transport: holds)
    assert_equal %w[completed applied], [record.reload.state, record.result]
    assert_equal ['active', 'free_completed', 2], [@account.reload.status, @account.internal_attributes.dig(Journal::KEY, 'state'), free_returns.count]
    assert_raises(InboxHold::Held) { InboxHold.with_inbox(@held, now: at + 240) { flunk 'held inbox operated' } }
    assert_empty sweep!(at + 480, transport: holds)
  end

  # (b) The last attempt fails before the return (Stripe read in its first Sync): the request ends
  # in attention with processing_unavailable and nothing in memory marks the suspension. The
  # durable facts do, and the sweep suspends the store.
  def test_last_attempt_failing_before_the_return_is_suspended_by_the_sweep
    holds, record = second_request_against_the_previous_bridge
    at = exhaust_but_last!(record, holds)
    @provider.before_read = lambda do
      @provider.before_read = nil
      raise Toybaco::Checkout::Error, 'fixture outage'
    end
    assert_equal 'attention', execute_sync(record, at: at, transport: holds)
    assert_equal %w[attention processing_unavailable active], [record.reload.state, record.result, @account.reload.status]
    assert_equal [record.id], sweep!(at + 60, transport: holds)
    assert_equal ['suspended', 'provider_closed'], [@account.reload.status, @account.internal_attributes.dig(Journal::KEY, 'state')]
  end

  # (c) The attention run ends before its suspension (a crash): the sweep suspends the store.
  def test_attention_run_that_ends_before_its_suspension_is_suspended_by_the_sweep
    holds, record = second_request_against_the_previous_bridge
    at = exhaust_but_last!(record, holds)
    crashed = Class.new(Toybaco::SubscriptionReconciliation::Execution) { define_method(:suspend_after_attention) { nil } }
    assert_equal 'attention', execute_sync(record, at: at, transport: holds, execution: crashed)
    assert_equal %w[attention free_return_pending active], [record.reload.state, record.result, @account.reload.status]
    assert_equal [record.id], sweep!(at + 60, transport: holds)
    assert_equal ['suspended', 'provider_closed'], [@account.reload.status, @account.internal_attributes.dig(Journal::KEY, 'state')]
  end

  # The suspension Sync may only suspend. A Sync that also changed the return (or turned the
  # paid contract into one that paid_contract? refuses) is rolled back whole, in the attention
  # run and in every sweep: the store stays active under its unfinished journal, the resumed
  # inbox stays usable, and the suspension stays due. A Sync that only suspends then commits.
  def test_suspension_sync_that_changes_the_return_is_rolled_back_and_stays_due
    holds, record = second_request_against_the_previous_bridge(resume: true)
    at = exhaust_but_last!(record, holds)
    kept = lambda do
      attrs = @account.reload.internal_attributes
      keys = [Journal::KEY, 'toybaco_subscription_id', 'toybaco_contract', PostingHold::KEY, InboxHold::KEY, FreeRecord::KEY]
      [@account.status, attrs.slice(*keys), free_returns.count]
    end
    original = Toybaco::StoreFulfillment.method(:synchronize)
    changing = lambda do |change|
      lambda do |account, **options, &check|
        return original.call(account, **options, &check) if options[:free_return]

        original.call(account, **options) do |*args|
          change.call(Account.find(account.id))
          check&.call(*args)
        end
      end
    end
    rewrite = ->(changes) { ->(store) { store.update_columns(internal_attributes: store.internal_attributes.deep_merge(changes)) } }
    changes = {
      journal_state: rewrite.call(Journal::KEY => { 'state' => 'free_completed' }),
      journal_binding: rewrite.call(Journal::KEY => { 'binding' => { 'subscription_id' => 'sub_other' } }),
      store_subscription: rewrite.call('toybaco_subscription_id' => 'sub_other'),
      free_contract: rewrite.call('toybaco_contract' => { 'plan_id' => 'free' }),
      contract_addons: rewrite.call('toybaco_contract' => { 'addons' => ['x'] }),
      contract_legacy: rewrite.call('toybaco_contract' => { 'legacy' => true }),
      contract_version: rewrite.call('toybaco_contract' => { 'plan_version' => '2026-09-18.1' }),
      contract_meter: rewrite.call('toybaco_contract' => { 'entitlements' => { 'ai_meter' => { 'unit' => 'fixture_meter' } } }),
      posting_hold: rewrite.call(PostingHold::KEY => { 'fixture' => true }),
      inbox_hold: rewrite.call(InboxHold::KEY => { 'fixture' => true }),
      pointer: rewrite.call(FreeRecord::KEY => { 'fixture' => true }),
      free_record: ->(store) { Toybaco::GrowthFreeReturn.create!(account_id: store.id, transition_id: 'f' * 64, receipt: { 'fixture' => true }) }
    }
    before = kept.call
    assert_equal 'active', before.first
    logged = []
    errors = ->(message = nil, &block) { logged << (message || block&.call) }
    changes.each_with_index do |(label, change), index|
      Rails.logger.stub(:error, errors) do
        Toybaco::StoreFulfillment.stub(:synchronize, changing.call(change)) do
          if index.zero?
            assert_equal 'attention', execute_sync(record, at: at, transport: holds), label.to_s
          else
            assert_equal [record.id], sweep!(at + (60 * index), transport: holds), label.to_s
          end
        end
      end
      assert_equal 1, logged.count('TOYBACO_SUBSCRIPTION_SYNC_SUSPENSION_INVARIANT'), label.to_s
      logged.clear
      assert_equal before, kept.call, label.to_s
      assert_equal 'attention', record.reload.state, label.to_s
      assert Toybaco::SubscriptionReconciliation.suspension_due?(record), label.to_s
      assert_equal :usable, InboxHold.with_inbox(@held, now: at) { :usable }, label.to_s
    end
    assert_equal [record.id], sweep!(at + (60 * changes.size), transport: holds)
    assert_equal ['suspended', 'provider_closed', 1], [@account.reload.status, @account.internal_attributes.dig(Journal::KEY, 'state'), free_returns.count]
    assert_equal before[1].except('toybaco_contract'), @account.internal_attributes.slice(*before[1].keys).except('toybaco_contract')
  end

  # Resuming from the billing suspension needs this subscription's closed cancel journal with
  # both ids present Stripe ids (never nil == nil) and Stripe's closure evidence. The sweep's
  # latch stays looser on the evidence: a malformed binding still falls back to the suspension.
  def test_resume_from_the_suspension_needs_both_subscription_ids_and_the_cancel_evidence
    rules = Toybaco::Growth::PeriodEndCancel
    suspended = Account.new(status: :suspended)
    closed = { 'state' => 'provider_closed', 'binding' => { 'subscription_id' => 'sub_second', 'cancel' => evidence } }
    attrs = lambda do |journal, current = 'sub_second'|
      { 'toybaco_billing_suspended' => true, 'toybaco_subscription_id' => current, Journal::KEY => journal }.compact
    end
    rebound = ->(changes) { closed.merge('binding' => closed['binding'].merge(changes)) }
    assert rules.store?(suspended, attrs.call(closed)), 'the closed cancel journal of this subscription'
    assert rules.return_latched?(attrs.call(closed), 'sub_second'), 'the latch of this subscription'
    anonymous = closed.merge('binding' => closed['binding'].except('subscription_id'))
    refute rules.closed_journal?(attrs.call(anonymous, nil)), 'both ids missing'
    refute rules.store?(suspended, attrs.call(anonymous, nil)), 'both ids missing'
    refute rules.store?(suspended, attrs.call(rebound.call('subscription_id' => nil), nil)), 'both ids nil'
    ['sub-second', 'sub_', '', 42].each do |id|
      refute rules.store?(suspended, attrs.call(rebound.call('subscription_id' => id), id)), "ids #{id.inspect}"
    end
    [nil, {}, true, evidence.except('reason'), evidence.merge('ended_at' => ENDED_AT.to_s)].each do |cancel|
      malformed = attrs.call(rebound.call('cancel' => cancel))
      refute rules.store?(suspended, malformed), "cancel #{cancel.inspect}"
      assert rules.return_latched?(malformed, 'sub_second'), "latched with cancel #{cancel.inspect}"
    end
    refute rules.return_latched?(attrs.call(anonymous, nil), nil), 'no subscription on either side'
    refute rules.return_latched?(attrs.call(closed.merge('binding' => closed['binding'].except('cancel'))), 'sub_second'), 'no cancel'
    refute rules.return_latched?(attrs.call(closed, 'sub_other'), 'sub_second'), 'the store moved to another subscription'
  end

  # The sweep's latch does not check the cancel evidence: a store whose unfinished cancel
  # journal lost its evidence shape still falls back to the suspension, and never resumes.
  def test_malformed_cancel_binding_is_still_suspended_by_the_sweep_and_never_resumes
    holds, record = second_request_against_the_previous_bridge
    at = exhaust_but_last!(record, holds)
    crashed = Class.new(Toybaco::SubscriptionReconciliation::Execution) { define_method(:suspend_after_attention) { nil } }
    assert_equal 'attention', execute_sync(record, at: at, transport: holds, execution: crashed)
    malformed = @account.reload.internal_attributes.deep_merge(Journal::KEY => { 'binding' => { 'cancel' => { 'ended_at' => @second_end.to_s } } })
    @account.update_columns(internal_attributes: malformed)
    refute Toybaco::Growth::PeriodEndCancel.unfinished_journal?(malformed)
    assert Toybaco::SubscriptionReconciliation.suspension_due?(record)
    assert_equal [record.id], sweep!(at + 60, transport: holds)
    assert_equal ['suspended', true], [@account.reload.status, @account.internal_attributes['toybaco_billing_suspended']]
    refute Finalizer.applicable?(@account)
    holds.old_bridge = false
    rearm!(record, at + 120)
    assert_equal [record.id], sweep!(at + 120, transport: holds)
    assert_equal ['completed', 'suspended', 1], [record.reload.state, @account.reload.status, free_returns.count]
    assert_equal malformed[Journal::KEY], @account.internal_attributes[Journal::KEY]
  end

  # The sweep selects in SQL what SubscriptionReconciliation.suspension_due? takes. Older
  # attention requests that it refuses (a renewal failure journal without a cancel binding on
  # a store still unpaid, a store that moved to another subscription, a store on an earlier
  # growth version) never enter the candidates, so they cannot crowd a due store out of the batch.
  def test_sweep_candidates_leave_refused_attention_out_of_the_batch
    synchronize
    assert_equal 'free_pending', finalize(transport: lost_response)
    due = accept_sync
    due.update_columns(account_id: @account.id, state: 'attention', next_enqueue_at: NOW - 60)
    attrs = @account.reload.internal_attributes
    journal = attrs.fetch(Journal::KEY)
    failure = journal.merge('state' => 'prepared', 'binding' => journal['binding'].except('cancel').merge('subscription_id' => 'sub_failure', 'failure' => {}))
    refused = {
      'sub_failure' => attrs.merge('toybaco_subscription_id' => 'sub_failure', 'toybaco_subscription_status' => 'past_due', Journal::KEY => failure),
      'sub_moved' => attrs.merge('toybaco_subscription_id' => 'sub_other', Journal::KEY => journal.deep_merge('binding' => { 'subscription_id' => 'sub_moved' })),
      'sub_earlier' => attrs.merge('toybaco_subscription_id' => 'sub_earlier', 'toybaco_contract' => attrs['toybaco_contract'].merge('plan_version' => '2026-09-18.1'))
    }
    refused.each_with_index do |(subscription, store_attrs), index|
      store = create(:account)
      store.update_columns(internal_attributes: store_attrs)
      request = accept_sync(subscription: subscription)
      request.update_columns(account_id: store.id, state: 'attention', next_enqueue_at: NOW - 3600 + index)
      refute Toybaco::SubscriptionReconciliation.suspension_due?(request), subscription
    end
    assert Toybaco::SubscriptionReconciliation.suspension_due?(due)
    job = Toybaco::SubscriptionReconciliationSweepJob.new
    assert_equal [due.id], job.send(:suspension_candidates, NOW).map(&:id)
    stub_const(Toybaco::SubscriptionReconciliationSweepJob, :SUSPENSION_BATCH, 1) do
      assert_equal [due.id], job.send(:suspension_candidates, NOW).map(&:id)
    end
  end

  # A return that ends in attention before its journal (the first return's pointer moved) and
  # whose same-run suspension fails leaves the store active with no journal of this
  # subscription. The Sync's own mark of the skipped suspension keeps it due: the sweep
  # suspends it, and without a journal of this subscription it never resumes from there.
  def test_attention_before_the_journal_whose_suspension_fails_is_suspended_by_the_sweep
    holds = PostizHolds.new
    first = return_first_cycle(holds)
    repurchase!
    end_second_subscription
    attrs = @account.reload.internal_attributes
    @account.update_columns(internal_attributes: attrs.deep_merge(FreeRecord::KEY => { 'returned_at' => first['returned_at'] + 1 }))
    record = accept_sync(at: second_at, subscription: @second_sub)
    synchronize = Toybaco::StoreFulfillment.method(:synchronize)
    failing = lambda do |account, **options, &check|
      raise Toybaco::Checkout::Error, 'fixture outage' unless options[:free_return]

      synchronize.call(account, **options, &check)
    end
    Toybaco::StoreFulfillment.stub(:synchronize, failing) { assert_equal 'attention', execute_sync(record, at: second_at, transport: holds) }
    assert_equal %w[attention attention active], [record.reload.state, record.result, @account.reload.status]
    attrs = @account.internal_attributes
    assert_equal ['free_completed', 1], [attrs.dig(Journal::KEY, 'state'), holds.requests.size]
    refute Toybaco::Growth::PeriodEndCancel.return_latched?(attrs, @second_sub)
    assert Toybaco::SubscriptionReconciliation.suspension_due?(record)
    assert_equal [record.id], sweep!(second_at + 60, transport: holds)
    attrs = @account.reload.internal_attributes
    assert_equal ['suspended', true, 'free_completed', 1],
                 [@account.status, attrs['toybaco_billing_suspended'], attrs.dig(Journal::KEY, 'state'), free_returns.count]
    assert_equal [false, []], [Toybaco::SubscriptionReconciliation.suspension_due?(record), sweep!(second_at + 180, transport: holds)]
    refute Finalizer.applicable?(@account), 'no journal of this subscription: it never resumes'
  end

  # A renewal dispatch of this subscription, written directly: the smallest billing event,
  # invoice fact and renewal operation that its foreign keys need (teardown removes them).
  def renewal_dispatch!(subscription, state:, phase: 'received', due_at: nil)
    suffix = SecureRandom.hex(6)
    event = Toybaco::BillingEvent.create!(event_id: "evt_dispatch#{suffix}", mode: 'test', action: 'subscription_notice',
                                          reference_id: subscription, snapshot: { 'fixture' => true }, payload_digest: 'd' * 64,
                                          state: 'completed', next_attempt_at: NOW, deadline_at: NOW + 1.day)
    operation = Toybaco::RenewalOperation.create!(mode: 'test', subscription_id: subscription, customer_id: "cus_dispatch#{suffix}",
                                                  invoice_id: "in_dispatch#{suffix}")
    fact = Toybaco::RenewalInvoiceFact.create!(billing_event_id: event.id, renewal_operation_id: operation.id, event_id: event.event_id,
                                               event_type: 'invoice.payment_failed', mode: 'test', subscription_id: subscription,
                                               customer_id: operation.customer_id, invoice_id: operation.invoice_id, payload_digest: 'd' * 64,
                                               attempt_count: 1, event_created_at: NOW)
    (@dispatch_fixtures ||= []) << [operation.id, fact.id, event.id]
    Toybaco::GrowthRenewalDispatch.create!(renewal_operation_id: operation.id, requested_fact_id: fact.id, state: state, phase: phase,
                                           due_at: due_at, deadline_at: NOW + 1.day, next_attempt_at: NOW, next_enqueue_at: NOW)
  end

  # The lock-inside decision and the sweep's candidates, at one time.
  def suspension_view(record, now)
    [Toybaco::SubscriptionReconciliation.suspension_due?(record.reload),
     Toybaco::SubscriptionReconciliationSweepJob.new.send(:suspension_candidates, now).map(&:id)]
  end

  # A renewal_pending attention is left out only while a renewal dispatch row of its subscription
  # can still re-arm it (SubscriptionReconciliation.rearming_dispatch?): a pending or running row, or an idle grace row
  # before or after its due date. With no rows, or only an attention row that is never claimed
  # again, it is due like any attention and the sweep suspends the store. The finished dispatch
  # re-arms it (rearm_waiting!) and the return continues, lifting the suspension.
  def test_renewal_pending_attention_is_left_out_only_while_a_dispatch_can_rearm_it
    holds, record = second_request_against_the_previous_bridge
    at = exhaust_but_last!(record, holds)
    crashed = Class.new(Toybaco::SubscriptionReconciliation::Execution) { define_method(:suspend_after_attention) { nil } }
    assert_equal 'attention', execute_sync(record, at: at, transport: holds, execution: crashed)
    record.update_columns(result: 'renewal_pending')
    assert_equal [true, [record.id]], suspension_view(record, at + 60), 'no dispatch rows'
    dispatch = renewal_dispatch!(@second_sub, state: 'pending')
    assert_equal [false, []], suspension_view(record, at + 60), 'a pending dispatch'
    dispatch.update_columns(state: 'running', lease_token: 'fixture-lease', lease_expires_at: at + 300)
    assert_equal [false, []], suspension_view(record, at + 60), 'a running dispatch'
    dispatch.update_columns(state: 'idle', phase: 'grace_ready', due_at: at + 3600, lease_token: nil, lease_expires_at: nil)
    assert_equal [false, []], suspension_view(record, at + 60), 'a grace row before its due date'
    assert_empty sweep!(at + 60, transport: holds)
    assert_equal ['active', 'provider_closed'], [@account.reload.status, @account.internal_attributes.dig(Journal::KEY, 'state')]
    dispatch.update_columns(due_at: at + 30)
    assert_equal [false, []], suspension_view(record, at + 60), 'a grace row past its due date'
    dispatch.update_columns(state: 'attention', phase: 'received', result: 'retry_limit', due_at: nil)
    assert_equal [true, [record.id]], suspension_view(record, at + 60), 'an attention dispatch'
    assert_equal [record.id], sweep!(at + 60, transport: holds)
    assert_equal ['suspended', 'provider_closed'], [@account.reload.status, @account.internal_attributes.dig(Journal::KEY, 'state')]
    dispatch.update_columns(state: 'idle', phase: 'paid_ready', result: 'paid_ready')
    holds.old_bridge = false
    assert Toybaco::SubscriptionReconciliation.rearm_waiting!(record.reload, now: at + 120)
    assert_equal [record.id], sweep!(at + 120, transport: holds)
    assert_equal %w[completed applied], [record.reload.state, record.result]
    assert_equal ['active', false, 'free_completed', 2], [@account.reload.status, @account.internal_attributes['toybaco_billing_suspended'],
                                                          @account.internal_attributes.dig(Journal::KEY, 'state'), free_returns.count]
  end

  # The same before any journal: a store that shows the Sync's mark of the skipped suspension is
  # left out while a dispatch of its subscription can still re-arm the request, and suspended by
  # the sweep once only an attention dispatch is left. Without a journal it never resumes.
  def test_renewal_pending_attention_before_the_journal_is_left_out_only_while_a_dispatch_can_rearm_it
    holds = PostizHolds.new
    first = return_first_cycle(holds)
    repurchase!
    end_second_subscription
    attrs = @account.reload.internal_attributes
    @account.update_columns(internal_attributes: attrs.deep_merge(FreeRecord::KEY => { 'returned_at' => first['returned_at'] + 1 }))
    record = accept_sync(at: second_at, subscription: @second_sub)
    crashed = Class.new(Toybaco::SubscriptionReconciliation::Execution) { define_method(:suspend_after_attention) { nil } }
    assert_equal 'attention', execute_sync(record, at: second_at, transport: holds, execution: crashed)
    attrs = @account.reload.internal_attributes
    assert Toybaco::Growth::PeriodEndCancel.suspension_skipped?(attrs, @second_sub)
    refute Toybaco::Growth::PeriodEndCancel.return_latched?(attrs, @second_sub)
    record.update_columns(result: 'renewal_pending')
    assert_equal [true, [record.id]], suspension_view(record, second_at + 60), 'no dispatch rows'
    dispatch = renewal_dispatch!(@second_sub, state: 'pending')
    assert_equal [false, []], suspension_view(record, second_at + 60), 'a pending dispatch'
    assert_empty sweep!(second_at + 60, transport: holds)
    assert_equal 'active', @account.reload.status
    dispatch.update_columns(state: 'attention', result: 'retry_limit')
    assert_equal [true, [record.id]], suspension_view(record, second_at + 60), 'an attention dispatch'
    assert_equal [record.id], sweep!(second_at + 60, transport: holds)
    attrs = @account.reload.internal_attributes
    assert_equal ['suspended', true, 'free_completed'], [@account.status, attrs['toybaco_billing_suspended'], attrs.dig(Journal::KEY, 'state')]
    refute Finalizer.applicable?(@account), 'no journal of this subscription: it never resumes'
  end

  # A re-armed request that expires unrun (a lost queue) records renewal_pending: its result is
  # empty, which counts as a waiting cause. No renewal dispatch runs for the ended subscription,
  # so nothing would re-arm it. It is not left out: its expiring run tries the suspension at once
  # and, that failing here, the next sweep suspends the store with its journal kept. A later
  # re-arm continues the return from the suspension and lifts it.
  def test_rearmed_request_that_expires_unrun_is_suspended
    holds, record = second_request_against_the_previous_bridge
    assert_equal 'pending', execute_sync(record, at: second_at, transport: holds)
    rearmed = second_at + 60
    rearm!(record, rearmed)
    late = rearmed + Toybaco::SubscriptionReconciliation::DEADLINE + 1
    synchronize = Toybaco::StoreFulfillment.method(:synchronize)
    tried = 0
    failing = lambda do |account, **options, &check|
      next synchronize.call(account, **options, &check) if options[:free_return]

      tried += 1
      raise Toybaco::Checkout::Error, 'fixture outage'
    end
    Toybaco::StoreFulfillment.stub(:synchronize, failing) { assert_equal 'attention', execute_sync(record, at: late, transport: holds) }
    assert_equal ['attention', 'renewal_pending', 1, 'active'], [record.reload.state, record.result, tried, @account.reload.status]
    refute Toybaco::Growth::RenewalDispatch.blocked?('test', @second_sub, now: late)
    assert_equal [record.id], sweep!(late + 60, transport: holds)
    attrs = @account.reload.internal_attributes
    assert_equal ['suspended', true, 'provider_closed'], [@account.status, attrs['toybaco_billing_suspended'], attrs.dig(Journal::KEY, 'state')]
    holds.old_bridge = false
    rearm!(record, late + 120)
    assert_equal [record.id], sweep!(late + 120, transport: holds)
    assert_equal %w[completed applied], [record.reload.state, record.result]
    attrs = @account.reload.internal_attributes
    assert_equal ['active', false, 'free_completed'], [@account.status, attrs['toybaco_billing_suspended'], attrs.dig(Journal::KEY, 'state')]
  end

  # Astra's path beside a dispatch that ended in attention (here claim!'s retry limit before any
  # work, phase received): it is never claimed again and would never re-arm anything. A request
  # re-armed and left unrun expires in renewal_pending, its run tries the suspension at once, and
  # the next sweep suspends the store when that failed. A later re-arm continues the return from
  # the suspension and lifts it.
  def test_rearmed_request_that_expires_unrun_beside_an_attention_dispatch_is_suspended
    holds, record = second_request_against_the_previous_bridge
    assert_equal 'pending', execute_sync(record, at: second_at, transport: holds)
    renewal_dispatch!(@second_sub, state: 'attention').update_columns(result: 'retry_limit')
    rearmed = second_at + 60
    rearm!(record, rearmed)
    late = rearmed + Toybaco::SubscriptionReconciliation::DEADLINE + 1
    synchronize = Toybaco::StoreFulfillment.method(:synchronize)
    tried = 0
    failing = lambda do |account, **options, &check|
      next synchronize.call(account, **options, &check) if options[:free_return]

      tried += 1
      raise Toybaco::Checkout::Error, 'fixture outage'
    end
    Toybaco::StoreFulfillment.stub(:synchronize, failing) { assert_equal 'attention', execute_sync(record, at: late, transport: holds) }
    assert_equal ['attention', 'renewal_pending', 1, 'active'], [record.reload.state, record.result, tried, @account.reload.status]
    assert Toybaco::Growth::RenewalDispatch.blocked?('test', @second_sub, now: late)
    refute Toybaco::SubscriptionReconciliation.rearming_dispatch?('test', @second_sub)
    assert_equal [record.id], sweep!(late + 60, transport: holds)
    attrs = @account.reload.internal_attributes
    assert_equal ['suspended', true, 'provider_closed'], [@account.status, attrs['toybaco_billing_suspended'], attrs.dig(Journal::KEY, 'state')]
    holds.old_bridge = false
    rearm!(record, late + 120)
    assert_equal [record.id], sweep!(late + 120, transport: holds)
    assert_equal %w[completed applied], [record.reload.state, record.result]
    attrs = @account.reload.internal_attributes
    assert_equal ['active', false, 'free_completed'], [@account.status, attrs['toybaco_billing_suspended'], attrs.dig(Journal::KEY, 'state')]
  end

  # A dispatch row that ended in attention after its grace (its N2 failed for good) holds the
  # renewal barrier: blocked, and not repair admissible, so the Sync waits behind it.
  def terminal_grace_dispatch!(at)
    dispatch = renewal_dispatch!(@second_sub, state: 'attention', phase: 'grace_ready', due_at: at)
    assert Toybaco::Growth::RenewalDispatch.blocked?('test', @second_sub, now: at)
    refute Toybaco::Growth::RenewalDispatch.repair_admissible?('test', @second_sub, now: at)
    dispatch
  end

  # A renewal coordinator of the dispatch's operation, in the sync cases' shape (its due_at may
  # not follow its creation); teardown removes it before the operation.
  def renewal_coordinator!(dispatch, phase:, at:)
    Toybaco::GrowthRenewalCoordinator.create!(account_id: @account.id, renewal_operation_id: dispatch.renewal_operation_id,
                                              operation_id: SecureRandom.hex(32), receipt_hash: SecureRandom.hex(32),
                                              receipt: { 'fixture' => true }, phase: phase, due_at: at - 60, created_at: at, updated_at: at)
  end

  def errors_logged
    logged = []
    Rails.logger.stub(:error, ->(message = nil, &block) { logged << (message || block&.call) }) { yield }
    logged
  end

  # One free_pending attempt, a re-arm, and no run until past the re-armed deadline.
  def rearmed_and_left_unrun(record, holds)
    assert_equal 'pending', execute_sync(record, at: second_at, transport: holds)
    rearm!(record, second_at + 60)
    second_at + 60 + Toybaco::SubscriptionReconciliation::DEADLINE + 1
  end

  # Behind a barrier held only by a terminal attention grace row the Sync waits for good. The
  # Free return's attention still falls back to the suspension through the suspension-only
  # path, in the expiring run itself: the journal stays and a later run of the suspended store
  # reads nothing. Once the dispatch attention is resolved, a re-arm completes the return and
  # lifts the suspension.
  def test_suspension_only_path_suspends_behind_a_terminal_attention_dispatch
    holds, record = second_request_against_the_previous_bridge
    late = rearmed_and_left_unrun(record, holds)
    dispatch = terminal_grace_dispatch!(late)
    reads = @provider.reads
    logged = errors_logged { assert_equal 'attention', execute_sync(record, at: late, transport: holds) }
    attrs = @account.reload.internal_attributes
    assert_equal %w[attention renewal_pending], [record.reload.state, record.result]
    assert_equal ['suspended', true, 'provider_closed', reads + 1],
                 [@account.status, attrs['toybaco_billing_suspended'], attrs.dig(Journal::KEY, 'state'), @provider.reads]
    assert_empty logged.grep(/SUSPENSION_(RETRY|BLOCKED|INVARIANT)/)
    assert_equal 'attention', execute_sync(record, at: late + 60, transport: holds)
    assert_equal reads + 1, @provider.reads, 'a suspended store is not read again'
    dispatch.update_columns(state: 'idle', phase: 'free_completed', result: 'free_completed')
    holds.old_bridge = false
    rearm!(record, late + 120)
    assert_equal 'completed', execute_sync(record, at: late + 120, transport: holds)
    attrs = @account.reload.internal_attributes
    assert_equal ['active', false, 'free_completed'], [@account.status, attrs['toybaco_billing_suspended'], attrs.dig(Journal::KEY, 'state')]
  end

  # The same before any journal: the Sync's mark of the skipped suspension falls back to the
  # suspension behind the terminal row; without a journal of this subscription it never resumes.
  def test_suspension_only_path_suspends_a_store_before_its_journal_behind_a_terminal_dispatch
    holds = PostizHolds.new
    first = return_first_cycle(holds)
    repurchase!
    end_second_subscription
    attrs = @account.reload.internal_attributes
    @account.update_columns(internal_attributes: attrs.deep_merge(FreeRecord::KEY => { 'returned_at' => first['returned_at'] + 1 }))
    record = accept_sync(at: second_at, subscription: @second_sub)
    crashed = Class.new(Toybaco::SubscriptionReconciliation::Execution) { define_method(:suspend_after_attention) { nil } }
    assert_equal 'attention', execute_sync(record, at: second_at, transport: holds, execution: crashed)
    terminal_grace_dispatch!(second_at + 60)
    assert_equal 'attention', execute_sync(record, at: second_at + 60, transport: holds)
    attrs = @account.reload.internal_attributes
    assert_equal ['suspended', true, 'free_completed'], [@account.status, attrs['toybaco_billing_suspended'], attrs.dig(Journal::KEY, 'state')]
    refute Finalizer.applicable?(@account), 'no journal of this subscription: it never resumes'
  end

  # The suspension-only path writes nothing while the fresh subscription is not exempt (a
  # dispatch could still renew it): the renewal guard's :wait stands, and the run logs that the
  # suspension waited, for the sweep's retry.
  def test_suspension_only_path_writes_nothing_while_the_subscription_is_not_exempt
    holds, record = second_request_against_the_previous_bridge
    late = rearmed_and_left_unrun(record, holds)
    terminal_grace_dispatch!(late)
    @provider.sub = @provider.sub.merge('status' => 'active', 'cancel_at_period_end' => false)
    before = [@account.reload.status, @account.internal_attributes]
    reads = @provider.reads
    logged = errors_logged { assert_equal 'attention', execute_sync(record, at: late, transport: holds) }
    assert_equal before, [@account.reload.status, @account.internal_attributes]
    assert_equal [reads + 1, 1], [@provider.reads, logged.count('TOYBACO_SUBSCRIPTION_SYNC_SUSPENSION_RETRY guard=wait')]
  end

  # A pending renewal coordinator keeps its fence: the suspension-only path neither reads Stripe
  # nor tries a write, logs once per run that it is blocked, and leaves the dispatch row, the
  # coordinator and the active store as they are, for the operator.
  def test_suspension_only_path_leaves_a_pending_coordinator_to_the_operator
    holds, record = second_request_against_the_previous_bridge
    late = rearmed_and_left_unrun(record, holds)
    dispatch = terminal_grace_dispatch!(late)
    coordinator = renewal_coordinator!(dispatch, phase: 'prepared', at: late)
    reads = @provider.reads
    expected = "TOYBACO_SUBSCRIPTION_SYNC_SUSPENSION_BLOCKED reason=coordinator subscription=#{@second_sub} account=#{@account.id}"
    %w[prepared waiting attention].each_with_index do |phase, index|
      coordinator.update_columns(phase: phase)
      kept = [dispatch.reload.attributes, coordinator.reload.attributes, @account.reload.status, @account.internal_attributes]
      logged = errors_logged { assert_equal 'attention', execute_sync(record, at: late + (60 * index), transport: holds) }
      assert_equal [1, reads], [logged.count(expected), @provider.reads], phase
      assert_equal kept, [dispatch.reload.attributes, coordinator.reload.attributes, @account.reload.status, @account.internal_attributes], phase
    end
  end

  # While any dispatch row of the subscription can still re-arm the request (pending, running, or
  # an idle grace row before or past its due date: rearming_dispatch? does not read the due date),
  # the suspension-only path stays out, also for a result that is not renewal_pending: no Stripe
  # read, the store stays active.
  def test_suspension_only_path_waits_while_a_dispatch_row_can_rearm
    holds, record = second_request_against_the_previous_bridge
    late = rearmed_and_left_unrun(record, holds)
    terminal_grace_dispatch!(late)
    record.update_columns(state: 'attention', result: 'retry_limit', next_enqueue_at: late)
    assert Toybaco::SubscriptionReconciliation.suspension_due?(record.reload)
    reads = @provider.reads
    [['pending', 'pending', {}], ['running', 'running', { lease_token: 'fixture-lease', lease_expires_at: late + 300 }],
     ['a grace row before its due date', 'idle', { phase: 'grace_ready', due_at: late + 3600 }],
     ['a grace row past its due date', 'idle', { phase: 'grace_ready', due_at: late - 3600 }]].each_with_index do |(label, state, columns), index|
      row = renewal_dispatch!(@second_sub, state: 'pending')
      row.update_columns(state: state, **columns)
      assert_equal 'attention', execute_sync(record, at: late + (60 * index), transport: holds), label
      assert_equal ['active', reads], [@account.reload.status, @provider.reads], label
      Toybaco::GrowthRenewalDispatch.where(id: row.id).delete_all
    end
  end

  # The suspension-only guard turns the renewal guard's :wait into the full Sync only for an
  # exempt subscription whose status the Sync suspends on, and only while terminal attention
  # rows alone hold the barrier.
  def test_suspension_only_guard_lets_only_an_exempt_subscription_past_terminal_attention_rows
    holds, record = second_request_against_the_previous_bridge
    late = rearmed_and_left_unrun(record, holds)
    terminal_grace_dispatch!(late)
    guard = Toybaco::SubscriptionReconciliation::Execution.new(record, client: @provider, now: late, environment: environment)
                                                          .send(:suspension_guard)
    ended = @provider.sub
    active = ended.merge('status' => 'active', 'cancel_at_period_end' => false)
    invoice = active['latest_invoice'].is_a?(Hash) ? active['latest_invoice'] : { 'id' => active['latest_invoice'] }
    void = active.merge('latest_invoice' => invoice.merge('status' => 'void'))
    travel_to(late) do
      assert_nil guard.call(@account.reload, ended), 'ended'
      assert_equal :wait, guard.call(@account, active), 'active'
      assert_equal :wait, guard.call(@account, void), 'an active subscription with a void latest invoice'
      assert_nil guard.call(@account, void.merge('status' => 'unpaid')), 'unpaid with a void latest invoice'
      expired = ended.merge('status' => 'incomplete_expired')
      assert_nil guard.call(@account, expired), 'incomplete_expired within the billing policy'
      narrow = @account.internal_attributes.deep_merge('toybaco_contract' => { 'billing_policy' => { 'suspended_statuses' => ['canceled'] } })
      @account.update_columns(internal_attributes: narrow)
      assert_equal :wait, guard.call(@account.reload, expired), 'incomplete_expired outside the billing policy'
      renewal_dispatch!(@second_sub, state: 'pending')
      assert_equal :wait, guard.call(@account, ended), 'a dispatch row that can re-arm'
    end
  end

  # The latest invoice of the fresh subscription is void, so it is exempt, but it is active: the
  # full Sync would not suspend it and would only overwrite the saved cancellation. The
  # suspension-only path writes nothing, logs that the suspension waited, and the store stays
  # due for the sweep, with its journal or with only the Sync's mark of the skipped suspension.
  def active_subscription_with_a_void_invoice
    invoice = @provider.sub['latest_invoice'].is_a?(Hash) ? @provider.sub['latest_invoice'] : { 'id' => @provider.sub['latest_invoice'] }
    @provider.sub.merge('status' => 'active', 'cancel_at_period_end' => false, 'latest_invoice' => invoice.merge('status' => 'void'))
  end

  def assert_nothing_written_behind_the_barrier(record, at, holds)
    before = [@account.reload.status, @account.internal_attributes]
    assert_equal %w[canceled true], before.last.values_at('toybaco_subscription_status', 'toybaco_cancel_at_period_end').map(&:to_s)
    @provider.sub = active_subscription_with_a_void_invoice
    logged = errors_logged { assert_equal 'attention', execute_sync(record, at: at, transport: holds) }
    assert_equal before, [@account.reload.status, @account.internal_attributes]
    assert_equal 1, logged.count('TOYBACO_SUBSCRIPTION_SYNC_SUSPENSION_RETRY guard=wait')
    assert Toybaco::SubscriptionReconciliation.suspension_due?(record.reload)
  end

  def test_suspension_only_path_writes_nothing_for_an_active_subscription_with_a_void_invoice
    holds, record = second_request_against_the_previous_bridge
    late = rearmed_and_left_unrun(record, holds)
    terminal_grace_dispatch!(late)
    assert_nothing_written_behind_the_barrier(record, late, holds)
    assert_equal 'provider_closed', @account.internal_attributes.dig(Journal::KEY, 'state')
  end

  def test_suspension_only_path_writes_nothing_before_the_journal_for_an_active_subscription_with_a_void_invoice
    holds = PostizHolds.new
    first = return_first_cycle(holds)
    repurchase!
    end_second_subscription
    attrs = @account.reload.internal_attributes
    @account.update_columns(internal_attributes: attrs.deep_merge(FreeRecord::KEY => { 'returned_at' => first['returned_at'] + 1 }))
    record = accept_sync(at: second_at, subscription: @second_sub)
    crashed = Class.new(Toybaco::SubscriptionReconciliation::Execution) { define_method(:suspend_after_attention) { nil } }
    assert_equal 'attention', execute_sync(record, at: second_at, transport: holds, execution: crashed)
    terminal_grace_dispatch!(second_at + 60)
    assert_nothing_written_behind_the_barrier(record, second_at + 60, holds)
    assert Toybaco::Growth::PeriodEndCancel.suspension_skipped?(@account.internal_attributes, @second_sub)
  end

  # A notification that re-arms the request (another session) while the suspension Sync reads
  # Stripe wins: right after the read, before any write, the Sync's guard locks the request
  # row, finds another state and revision, and rolls the suspension back whole. Postiz is
  # never disabled: its own database would keep the disabling and the revoked API key, which
  # the rollback cannot restore. The store stays active and the re-armed run continues the return.
  def test_suspension_rolls_back_when_a_notification_rearms_the_request_during_its_provider_read
    holds, record = second_request_against_the_previous_bridge
    late = rearmed_and_left_unrun(record, holds)
    notified = false
    @provider.before_read = lambda do
      next if notified

      notified = true
      Thread.new do
        Account.connection_pool.with_connection { Toybaco::SubscriptionReconciliation.request!(@second_sub, mode: 'test', now: late) }
      end.join
    end
    disabled = []
    revoke = lambda do |**|
      disabled << :disabled
      :not_managed
    end
    logged = Toybaco::SubscriptionReconciliationJob.stub(:perform_later, ->(*) { true }) do
      Toybaco::PostizSync.stub(:disable_account!, revoke) do
        errors_logged { assert_equal 'attention', execute_sync(record, at: late, transport: holds) }
      end
    end
    assert notified
    assert_empty disabled, 'disable_account! was called before the rollback: Postiz keeps the disabling and the revoked API key'
    assert_equal ['pending', nil, 'active'], [record.reload.state, record.result, @account.reload.status]
    assert_equal ['provider_closed', 1], [@account.internal_attributes.dig(Journal::KEY, 'state'),
                                          logged.count('TOYBACO_SUBSCRIPTION_SYNC_SUSPENSION_INVARIANT')]
    @provider.before_read = nil
    holds.old_bridge = false
    assert_equal 'completed', execute_sync(record, at: late + 60, transport: holds)
    assert_equal ['active', 'free_completed'], [@account.reload.status, @account.internal_attributes.dig(Journal::KEY, 'state')]
  end

  # A return that ends in its own attention (here the first return's pointer moved) needs an
  # operator at once: that run suspends the store as before and writes nothing of the return.
  # Without a closed journal of this subscription the return does not continue from there.
  def test_free_return_attention_suspends_the_store_in_the_same_run
    holds = PostizHolds.new
    first = return_first_cycle(holds)
    repurchase!
    end_second_subscription
    attrs = @account.reload.internal_attributes
    @account.update_columns(internal_attributes: attrs.deep_merge(FreeRecord::KEY => { 'returned_at' => first['returned_at'] + 1 }))
    record = accept_sync(at: second_at, subscription: @second_sub)
    Toybaco::PostizSync.stub(:disable_account!, ->(**) { :not_managed }) do
      assert_equal 'attention', execute_sync(record, at: second_at, transport: holds)
    end
    assert_equal %w[attention attention], [record.reload.state, record.result]
    attrs = @account.reload.internal_attributes
    assert_equal ['suspended', true, 'free_completed', 1, 1], [@account.status, attrs['toybaco_billing_suspended'],
                                                               attrs.dig(Journal::KEY, 'state'), holds.requests.size, free_returns.count]
    refute Finalizer.applicable?(@account)
  end

  # A free_return_pending request whose deadline passes between runs (a delayed schedule)
  # ends in attention when it is next due; that run suspends the store the same way.
  def test_free_return_past_its_deadline_suspends_the_store
    holds = PostizHolds.new
    return_first_cycle(holds)
    repurchase!
    holds.old_bridge = true
    end_second_subscription
    record = accept_sync(at: second_at, subscription: @second_sub)
    assert_equal 'pending', execute_sync(record, at: second_at, transport: holds)
    assert_equal ['free_return_pending', 'active'], [record.reload.result, @account.reload.status]
    late = record.deadline_at + 1
    Toybaco::PostizSync.stub(:disable_account!, ->(**) { :not_managed }) do
      assert_equal 'attention', execute_sync(record, at: late, transport: holds)
    end
    assert_equal ['attention', 'retry_limit', 1], [record.reload.state, record.result, record.attempts]
    assert_equal ['suspended', 'provider_closed', 2], [@account.reload.status, @account.internal_attributes.dig(Journal::KEY, 'state'),
                                                       holds.requests.size]
    assert Finalizer.applicable?(@account), 'the return may continue from its own suspension'
  end

  # The completed return loses its pointer after the second journal was written: the next
  # generation stops before HTTP as Changed (attention), never as a retried invalid response,
  # and never guesses the latest return as its parent (Postiz would replace its generation).
  def test_missing_return_pointer_stops_the_next_generation_before_http
    holds = PostizHolds.new
    first = return_first_cycle(holds)
    repurchase!
    assert_equal 'applied', synchronize_second
    holds.old_bridge = true
    assert_equal 'free_pending', finalize_second(holds)
    holds.old_bridge = false
    detached = @account.reload.internal_attributes.except(FreeRecord::KEY)
    @account.update_columns(internal_attributes: detached)
    requests = holds.requests.size
    assert_raises(Journal::Changed) do
      travel_to(second_at) { PostingHold.new(@account.reload, environment: environment, transport: holds, clock: -> { second_at }).call }
    end
    assert_equal 'attention', finalize_second(holds)
    assert_equal [requests, 1], [holds.requests.size, holds.generations.size]
    assert_equal [detached, first['posting'], 1], [@account.reload.internal_attributes, @account.internal_attributes[PostingHold::KEY],
                                                   free_returns.count]
  end

  # The same inputs as postiz/tests/posting-retention-bridge.test.js: the wire body of a
  # later stop and its six-key policy digest agree with the TypeScript bridge.
  def test_next_generation_request_matches_the_typescript_bridge_vector
    config = Protocol.configuration(environment)
    store = PostingHold.new(Struct.new(:id).new(42), environment: environment)
    policy = { 'organizationId' => Toybaco::PostizSync.deterministic_organization_id(42), 'transitionId' => 'e' * 64,
               'keepIntegrationIds' => ['integration_a'], 'scheduledPostsPerAccount' => 5,
               'previousTransitionId' => 'c' * 64, 'previousReceiptHash' => 'd' * 64 }
    body = store.send(:request, policy, config)
    assert_equal '59c99254-65ea-5c0e-96c7-5005c4343e39', policy['organizationId']
    assert_equal 'e3e59d2d2f40c8a2dbbf6d039401a1d1a9202d8b717c1f94a80803a7362777d2', body['policy_hash']
    assert_equal 'a396f4fc458b4ebf14b016c39067d3de6cb2f0c45b02ad3d977b69c740be54ca', Digest::SHA256.hexdigest(JSON.generate(body))
    first = store.send(:request, policy.except('previousTransitionId', 'previousReceiptHash'), config)
    assert_equal body.keys - %w[previous_transition_id previous_receipt_hash], first.keys
  end
end
