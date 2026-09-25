# frozen_string_literal: true

require 'rails/test_help'
require 'minitest/mock'
require 'factory_bot_rails'
require Rails.root.join('lib/toybaco/growth/period_end_free_return')
require Rails.root.join('lib/toybaco/growth/retention_selection')
require Rails.root.join('lib/toybaco/store_fulfillment')
require Rails.root.join('lib/toybaco/subscription_reconciliation/execution')

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
    attr_accessor :sub
    attr_reader :reads

    def initialize(sub)
      @sub = sub
      @reads = 0
    end

    def retrieve_subscription(id)
      @reads += 1
      raise Toybaco::Checkout::Unavailable, 'unknown subscription' unless id == sub['id']

      Marshal.load(Marshal.dump(sub))
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

  def accept_sync(at: NOW)
    record = Toybaco::SubscriptionReconciliationJob.stub(:perform_later, ->(*) { true }) do
      Toybaco::SubscriptionReconciliation.request!('sub_periodend', mode: 'test', now: at)
    end
    (@sync_receipts ||= []) << record.id
    record
  end

  def execute_sync(record, at: NOW, transport: @transport)
    Toybaco::Growth::RetentionTransport.stub(:new, ->(**) { transport }) do
      Toybaco::Growth::RetentionInventory.stub(:new, ->(*) { @inventory }) do
        travel_to(at) do
          Toybaco::SubscriptionReconciliation::Execution.new(record, client: @provider, now: at, environment: environment).call
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
end
