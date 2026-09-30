# frozen_string_literal: true

require Rails.root.join('lib/toybaco/growth/renewal_dispatch_execution')

# A renewal payment that never arrives: after the grace the dispatch row runs the stop (N2), the
# provider settlement (void, cancel), both holds and the Free write. Real database, dispatch rows,
# coordinator, settlement, holds and Free return; fixture Stripe, Postiz transport and connection
# inventory. Uses the continuation fixture (prepended before this module), with and without the
# in-app purchase record.
module ToybacoGrowthRenewalDispatchFreeCases
  Growth = Toybaco::Growth
  Dispatch = Growth::RenewalDispatch
  NOW = Time.utc(2026, 9, 24, 8)
  FLAGS = Growth::PeriodEndCancel::FLAGS
  HOLD_KEYS = [Growth::PostingRetention::KEY, Growth::InboxRetention::KEY].freeze

  def teardown
    if @free_fixture
      Toybaco::GrowthRenewalSettlement.where(account_id: @account.id).delete_all
      Toybaco::GrowthRenewalCoordinator.where(account_id: @account.id).delete_all
      Toybaco::GrowthPostingStop.where(account_id: @account.id).delete_all
    end
    super
  end

  # Three connections: Free keeps the two oldest inboxes and holds the newest one.
  def free_fixture(opening:)
    @free_fixture = true
    dispatch_ordinary_fixture(opening: opening)
    inboxes = 3.times.map { FactoryBot.create(:inbox, account: @account) }.sort_by(&:id)
    @free_kept = inboxes.first(2)
    rows = inboxes.each_with_index.map { |box, index| { 'id' => box.id.to_s, 'name' => 'private name', 'created_at_us' => (NOW.to_i * 1_000_000) + index } }
    @free_inventory = Struct.new(:rows) { def read = rows.deep_dup }.new({ 'inboxes' => rows, 'posting_accounts' => [], 'posts' => [] })
    @free_calls = []
    @free_postings = []
    @free_transport = lambda do |payload|
      raise 'the posting hold must run outside a transaction' if Account.connection.transaction_open?

      @free_postings << payload
      { 'version' => 1, 'request_sha256' => Digest::SHA256.hexdigest(JSON.generate(payload)),
        'organization_id' => payload.fetch('organization_id'), 'transition_id' => payload.fetch('transition_id'),
        'policy_hash' => payload.fetch('policy_hash'), 'receipt_hash' => 'b' * 64, 'kept_posts' => 0, 'held_posts' => 0 }
    end
    free_provider_actions
    assert_equal 'idle', free_execute(at: NOW)
    assert_equal 'grace_ready', dispatch_row.phase
  end

  # Voiding closes the invoice and cancelling ends the subscription, as Stripe answers.
  def free_provider_actions
    test = self
    @client.define_singleton_method(:void_invoice) do |id, idempotency_key:|
      raise 'provider called inside Account transaction' if Account.connection.transaction_open?
      raise 'missing deterministic idempotency key' unless idempotency_key.start_with?('toybaco-renewal-void-')

      test.instance_variable_get(:@free_calls) << [:void, id]
      test.instance_variable_get(:@subscription)['latest_invoice']['status'] = 'void'
    end
    @client.define_singleton_method(:cancel_unpaid_subscription) do |id|
      raise 'provider called inside Account transaction' if Account.connection.transaction_open?

      test.instance_variable_get(:@free_calls) << [:cancel, id]
      test.instance_variable_get(:@subscription)['status'] = 'canceled'
    end
  end

  def free_environment(changes = {})
    { 'TOYBACO_STRIPE_MODE' => 'test', 'TOYBACO_RENEWAL_SETTLEMENT_ENABLED' => 'true', 'TOYBACO_POSTING_STOP_ENABLED' => 'true',
      'TOYBACO_RENEWAL_PROVIDER_SETTLEMENT_ENABLED' => 'true', 'TOYBACO_POST_URL' => 'https://post.staging.toybaco.jp',
      'FRONTEND_URL' => 'https://app.staging.toybaco.jp', 'TOYBACO_OIDC_CLIENT_SECRET' => 'fixture-only-retention-secret-over-32-characters' }
      .merge(FLAGS.index_with { 'true' }).merge(changes)
  end

  def free_execute(at:, environment: free_environment, transport: @free_transport)
    travel_to at
    Growth::RetentionTransport.stub(:new, ->(**) { transport }) do
      Growth::RetentionInventory.stub(:new, ->(*, **) { @free_inventory }) do
        Growth::RenewalDispatchExecution.new(dispatch_row, client: @client, environment: environment, clock: -> { Time.now.utc }).call
      end
    end
  end

  def free_due = operation.due_at + 60
  def free_attrs = @account.reload.internal_attributes
  def free_coordinator = Toybaco::GrowthRenewalCoordinator.find_by!(renewal_operation_id: operation.id)
  def free_stop = Toybaco::GrowthPostingStop.find_by!(account_id: @account.id)
  def free_returns = Toybaco::GrowthFreeReturn.where(account_id: @account.id)

  # The store keeps its paid contract, subscription and stop until both holds and the Free write.
  def assert_free_not_written(label)
    attrs = free_attrs
    assert_equal [@dispatch_contract, @sub], attrs.values_at('toybaco_contract', 'toybaco_subscription_id'), label
    refute attrs.key?(Growth::InboxRetention::KEY), label
    refute attrs.key?(Growth::FreeReturnRecord::KEY), label
    assert_equal [0, 'pending', 'stop_recorded'], [free_returns.count, free_stop.state, free_coordinator.phase], label
  end

  { 'purchase_record' => false, 'opening_request' => true }.each do |label, opening|
    define_method("test_dispatch_free_unpaid_renewal_returns_to_free_with_both_holds_for_the_#{label}") do
      free_fixture(opening: opening)
      assert_equal 'idle', free_execute(at: free_due)
      assert_equal %w[idle free_completed], dispatch_row.values_at(:state, :phase)
      assert_equal [[:void, @invoice], [:cancel, @sub]], @free_calls
      attrs = free_attrs
      receipt = Growth::FreeReturnRecord.current(@account)
      journal = receipt.fetch('source_journal')
      assert_equal [Growth::FreeReturnRecord.free_contract, nil], [Toybaco::Entitlements.contract_for(@account), attrs['toybaco_subscription_id']]
      refute attrs.key?(Growth::PurchaseIntent::KEY)
      assert_equal(opening ? nil : { 'nonce' => 'a' * 48, 'state' => 'complete', 'subscription_id' => @sub, 'livemode' => false }, receipt['purchase'])
      assert_equal [[journal['id'], []]], @free_postings.map { |payload| payload.values_at('transition_id', 'keep_integration_ids') }
      assert_equal receipt['posting'], attrs[Growth::PostingRetention::KEY]
      assert_equal [journal['id'], @free_kept.map { |box| box.id.to_s }], attrs[Growth::InboxRetention::KEY].values_at('transition_id', 'keep_inbox_ids')
      assert_equal [1, 'applied', 'free_completed'], [free_returns.count, free_stop.state, free_coordinator.phase]
      assert_equal 'free_completed', Toybaco::GrowthRenewalSettlement.find_by!(coordinator_id: free_coordinator.id).phase
      assert_equal [20], Toybaco::GrowthAiGrant.where(account_id: @account.id, source: 'included').pluck(:units)
      refute Dispatch.blocked?('test', @sub, now: Time.now.utc)
      assert_equal 'idle', free_execute(at: free_due + 1.hour)
      assert_equal [1, 1, 2], [free_returns.count, @free_postings.size, @free_calls.size]
    end
  end

  # Each rollout flag alone keeps the provider-closed row pending: no hold, no Postiz call, no Free.
  def test_dispatch_free_half_open_rollout_stays_pending_without_holds
    free_fixture(opening: true)
    FLAGS.each_with_index do |flag, index|
      assert_equal 'pending', free_execute(at: free_due + (index * 5.minutes), environment: free_environment(flag => 'false')), flag
      assert_equal %w[pending provider_closed provider_closed], dispatch_row.values_at(:state, :phase, :result), flag
      assert_free_not_written(flag)
      refute free_attrs.key?(Growth::PostingRetention::KEY), flag
      assert_empty @free_postings, flag
    end
    assert_equal [[:void, @invoice], [:cancel, @sub]], @free_calls
    assert_equal 'idle', free_execute(at: free_due + 20.minutes)
    assert_equal %w[idle free_completed], dispatch_row.values_at(:state, :phase)
  end

  # A lost Postiz response is retried with the same transition, and the return completes once.
  def test_dispatch_free_lost_posting_response_is_pending_and_retries_the_same_transition
    free_fixture(opening: false)
    lost = lambda do |payload|
      @free_postings << payload
      raise Growth::RetentionProtocol::Invalid
    end
    assert_equal 'pending', free_execute(at: free_due, transport: lost)
    assert_equal %w[pending processing_unavailable], dispatch_row.values_at(:state, :result)
    assert_free_not_written('lost response')
    refute free_attrs.key?(Growth::PostingRetention::KEY)
    assert_equal 'idle', free_execute(at: free_due + 30.minutes)
    assert_equal %w[idle free_completed], dispatch_row.values_at(:state, :phase)
    journal = free_attrs[Growth::RenewalTransition::KEY]
    assert_equal [journal['id']] * 2, @free_postings.map { |payload| payload['transition_id'] }
    assert_equal 1, free_returns.count
  end

  # An opening store whose binding cannot be derived at the due time is never stopped: no coordinator,
  # posting stop, journal, Stripe call, hold or Free, and the row stops for an operator at its deadline.
  def test_dispatch_free_opening_store_without_a_binding_is_never_stopped_or_returned
    free_fixture(opening: true)
    Toybaco::OpeningRequest.where(id: @dispatch_opening_requests).delete_all
    assert_equal 'pending', free_execute(at: free_due)
    assert_equal 'processing_unavailable', dispatch_row.result
    refute Toybaco::GrowthRenewalCoordinator.exists?(renewal_operation_id: operation.id)
    refute Toybaco::GrowthPostingStop.exists?(account_id: @account.id)
    attrs = free_attrs
    assert_equal [@dispatch_contract, @sub], attrs.values_at('toybaco_contract', 'toybaco_subscription_id')
    refute(([Growth::RenewalTransition::KEY, Growth::FreeReturnRecord::KEY] + HOLD_KEYS).any? { |key| attrs.key?(key) })
    assert_equal [[], []], [@free_calls, @free_postings]
    assert_equal 'attention', free_execute(at: dispatch_row.deadline_at + 1)
    assert_equal %w[attention retry_limit], dispatch_row.values_at(:state, :result)
    assert_equal 0, free_returns.count
  end

  # A kept connection that disappeared after the choice stops the row for an operator: the inbox
  # hold and the Free write never happen, and the store keeps its paid contract and subscription.
  def test_dispatch_free_invalid_hold_needs_attention_and_writes_no_free
    free_fixture(opening: true)
    Inbox.where(id: @free_kept.first.id).delete_all
    assert_equal 'attention', free_execute(at: free_due)
    assert_equal %w[attention hold_attention], dispatch_row.values_at(:state, :result)
    assert_free_not_written('invalid hold')
    assert_equal 'provider_closed', free_attrs.dig(Growth::RenewalTransition::KEY, 'state')
    assert_equal 'attention', free_execute(at: free_due + 1.hour)
    assert_equal 0, free_returns.count
  end
end
