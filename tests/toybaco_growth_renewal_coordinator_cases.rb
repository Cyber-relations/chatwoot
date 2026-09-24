# frozen_string_literal: true

require Rails.root.join('lib/toybaco/growth/renewal_coordinator')

module ToybacoRenewalCoordinatorRuntimeCases
  N2 = Toybaco::Growth
  CoordinatorRow = Toybaco::GrowthRenewalCoordinator

  def teardown
    if @renewal_test_used
      CoordinatorRow.where(account_id: @account.id).delete_all
      Toybaco::GrowthAutoRequest.where(account_id: @account.id).delete_all
    end
    super
  end

  def n2_fixture
    _, operation = n3i_fixture
    n3_time(operation.due_at.to_i)
    @n2_operation = operation
    @n2_rows = { 'inboxes' => [], 'posting_accounts' => [], 'posts' => [] }
    operation
  end

  def n2_service(environment: {}, client: n3i_client)
    env = { 'TOYBACO_RENEWAL_SETTLEMENT_ENABLED' => 'true', 'TOYBACO_POSTING_STOP_ENABLED' => 'true', 'TOYBACO_STRIPE_MODE' => 'test' }.merge(environment)
    N2::RenewalCoordinator.new(@n2_operation.id, client: client, environment: env, clock: -> { n3_now }, inventory: Struct.new(:read).new(@n2_rows))
  end

  def n2_row = CoordinatorRow.find_by!(renewal_operation_id: @n2_operation.id)

  def n2_prepare_only
    N2::PostingStop.stub(:new, ->(*) { raise IOError, 'fixture before stop' }) { assert_raises(IOError) { n2_service.call } }
    assert_equal 'prepared', n2_row.phase
  end

  def n2_execution(state)
    Toybaco::GrowthPostingExecution.create!(account_id: @account.id, operation_id: SecureRandom.hex(32), identity_hash: SecureRandom.hex(32),
      request: { 'version' => 3, 'step' => 'MAIN' }, request_hash: SecureRandom.hex(32), state: state,
      started_at: state == 'prepared' ? nil : n3_now, uncertain_evidence_hash: state == 'uncertain' ? '6' * 64 : nil,
      created_at: n3_now, updated_at: n3_now)
  end

  def n2_execution_service
    id = SecureRandom.hex(32)
    request = { 'version' => 2, 'organization_id' => Toybaco::PostizSync.deterministic_organization_id(@account.id),
      'root_id' => id, 'step_id' => id, 'step' => 'MAIN', 'marker_hash' => '1' * 64,
      'contract_hash' => N2::PostingExecutionContext.contract_hash(@account.reload), 'authority_hash' => '2' * 64,
      'principal' => N2::PostingPrincipal.capture!(@account.id, actor_id: @owner.id, now: n3_now) }
    N2::PostingExecution.new(@account.id, operation_id: id, request: request,
      environment: { 'TOYBACO_POSTING_EXECUTION_ENABLED' => 'true' }, now: n3_now)
  end

  def test_n2_stop_wins_against_prepared_and_later_real_start_is_never_rearmed
    n2_fixture
    execution = n2_execution_service
    execution.prepare!
    result = n2_service.call
    assert_equal 'stop_recorded', result['phase']
    assert_equal ['cancelled', false], execution.start!.values_at('state', 'execute')
    assert_raises(N2::PostingStopContext::Busy) { n2_execution_service }
  end

  def test_n2_fixed_due_journal_target_and_one_stop_are_nonexecuting
    operation = n2_fixture
    contract = Toybaco::Entitlements.contract_for(@account).deep_dup
    result = n2_service.call
    assert_equal ['stop_recorded', false], result.values_at('phase', 'execute')
    receipt = n2_row.receipt.deep_dup
    assert_equal [operation.id, operation.due_at.to_i, 'ordinary_renewal'], receipt.values_at('renewal_operation_id', 'due_at', 'cause')
    assert_equal contract, Toybaco::Entitlements.contract_for(@account.reload)
    assert_equal 'prepared', receipt.dig('journal', 'state')
    assert_equal receipt['journal'], @account.internal_attributes[N2::RenewalTransition::KEY]
    assert_equal receipt['target_hash'], Toybaco::GrowthPostingStop.find_by!(account_id: @account.id).target_hash
    refute_includes receipt.to_json, 'private name'
    n3_time(n3_now.to_i + 86_400)
    assert_equal result, n2_service.call
    assert_equal receipt, n2_row.receipt
    assert_equal 1, CoordinatorRow.where(account_id: @account.id).count
    assert_equal 1, Toybaco::GrowthPostingStop.where(account_id: @account.id).count
  end

  def test_n2_deadline_flag_outer_transaction_and_mode_fail_closed
    n2_fixture
    n3_time(@n2_operation.due_at.to_i - 1)
    assert_raises(N2::RenewalCoordinatorRecord::Changed) { n2_service.call }
    n3_time(@n2_operation.due_at.to_i)
    assert_raises(N2::RenewalCoordinatorRecord::Invalid) { n2_service(environment: { 'TOYBACO_RENEWAL_SETTLEMENT_ENABLED' => 'false' }).call }
    @account.with_lock { assert_raises(N2::RenewalCoordinatorRecord::Invalid) { n2_service.call } }
    assert_raises(N2::RenewalCoordinatorRecord::Changed) { n2_service(environment: { 'TOYBACO_STRIPE_MODE' => 'live' }).call }
    refute CoordinatorRow.where(account_id: @account.id).exists?
    refute Toybaco::GrowthPostingStop.where(account_id: @account.id).exists?
  end

  def test_n2_mixed_invoice_and_paid_first_never_create_stop
    n2_fixture
    invoice = @n3_provider['latest_invoice'].deep_dup
    @n3_provider['latest_invoice']['lines']['data'] << invoice['lines']['data'].first.deep_dup
    assert_raises(N2::RenewalCoordinatorRecord::Changed) { n2_service.call }
    @n3_provider['latest_invoice'] = invoice.merge('status' => 'paid', 'amount_remaining' => 0, 'amount_paid' => invoice['amount_due'])
    assert_raises(N2::RenewalCoordinatorRecord::Changed) { n2_service.call }
    refute CoordinatorRow.where(account_id: @account.id).exists?
    refute Toybaco::GrowthPostingStop.where(account_id: @account.id).exists?
  end

  def test_n2_stripe_read_is_outside_account_transaction_and_principal_aba_is_rejected
    n2_fixture
    client = n3i_client
    original = client.method(:retrieve_subscription)
    account_id = @account.id
    client.define_singleton_method(:retrieve_subscription) do |id|
      Account.transaction { N2::PostingPrincipal.rotate!(account_id) }
      original.call(id)
    end
    assert_raises(N2::RenewalCoordinatorRecord::Changed) { n2_service(client: client).call }
    refute CoordinatorRow.where(account_id: @account.id).exists?
    refute Toybaco::GrowthPostingStop.where(account_id: @account.id).exists?
  end

  def test_n2_intent_insert_failure_rolls_back_real_journal_and_marker
    n2_fixture
    before = @account.reload.internal_attributes[N2::RenewalTransition::KEY].deep_dup
    hook = -> { raise IOError, 'fixture after coordinator insert' }
    CoordinatorRow.set_callback(:create, :after, hook)
    assert_raises(IOError) { n2_service.call }
    assert before == @account.reload.internal_attributes[N2::RenewalTransition::KEY]
    refute CoordinatorRow.where(account_id: @account.id).exists?
    refute Toybaco::GrowthPostingStop.where(account_id: @account.id).exists?
  ensure
    CoordinatorRow.skip_callback(:create, :after, hook) if hook
  end

  def test_n2_stop_and_phase_update_callback_failure_roll_back_together
    n2_fixture
    hook = -> { raise IOError, 'fixture after phase update' if phase == 'stop_recorded' }
    CoordinatorRow.set_callback(:update, :after, hook)
    assert_raises(IOError) { n2_service.call }
    receipt = n2_row.receipt.deep_dup
    assert_equal 'prepared', n2_row.phase
    refute Toybaco::GrowthPostingStop.where(account_id: @account.id).exists?
    CoordinatorRow.skip_callback(:update, :after, hook)
    hook = nil
    assert_equal 'stop_recorded', n2_service.call['phase']
    assert_equal receipt, n2_row.receipt
  ensure
    CoordinatorRow.skip_callback(:update, :after, hook) if hook
  end

  def test_n2_committed_stop_response_loss_recovers_same_operation_and_flag_off
    n2_fixture
    original = N2::PostingStop.method(:new)
    adapter = lambda do |*args, **kwargs|
      service = original.call(*args, **kwargs)
      request = service.method(:request!)
      service.define_singleton_method(:request!) { |**hooks| request.call(**hooks); raise IOError, 'fixture response loss' }
      service
    end
    N2::PostingStop.stub(:new, adapter) { assert_raises(IOError) { n2_service.call } }
    before = n2_row.receipt.deep_dup
    assert_equal 'stop_recorded', n2_row.phase
    result = n2_service(environment: { 'TOYBACO_RENEWAL_SETTLEMENT_ENABLED' => 'false', 'TOYBACO_POSTING_STOP_ENABLED' => 'false' }).call
    assert_equal ['stop_recorded', false], result.values_at('phase', 'execute')
    assert_equal before, n2_row.receipt
    assert_equal 1, Toybaco::GrowthPostingStop.where(account_id: @account.id).count
  end

  def test_n2_unstarted_cancelled_started_and_uncertain_kept_without_lease_completion
    n2_fixture
    prepared = n2_execution('prepared')
    started = n2_execution('started')
    unknown = n2_execution('uncertain')
    assert_equal 'waiting', n2_service.call['phase']
    assert_equal %w[cancelled started uncertain], [prepared.reload.state, started.reload.state, unknown.reload.state]
    n3_time(n3_now.to_i + 365.days.to_i)
    assert_equal 'waiting', n2_service(environment: { 'TOYBACO_RENEWAL_SETTLEMENT_ENABLED' => 'false' }).call['phase']
    assert_equal %w[started uncertain], [started.reload.state, unknown.reload.state]
  end

  def test_n2_managed_auto_unknown_waits_and_only_definitive_result_clears_wait
    n2_fixture
    request = Toybaco::GrowthAutoRequest.create!(account_id: @account.id, inbox_id: 1, installation_id: 1, message_id: 1,
      conversation_id: 1, generation: 1, epoch: SecureRandom.uuid, operation_id: 1, state: 'uncertain', started_at: n3_now, enqueue_after: n3_now)
    assert_equal 'waiting', n2_service.call['phase']
    n3_time(n3_now.to_i + 365.days.to_i)
    assert_equal 'waiting', n2_service.call['phase']
    request.update!(state: 'completed', terminal_at: n3_now)
    result = n2_service.call
    assert_equal ['stop_recorded', false], result.values_at('phase', 'execute')
  end

  def test_n2_prepared_payment_race_becomes_attention_without_rewriting_receipt
    n2_fixture
    n2_prepare_only
    before = n2_row.receipt.deep_dup
    invoice = @n3_provider['latest_invoice']
    @n3_provider['latest_invoice'] = invoice.merge('status' => 'paid', 'amount_remaining' => 0, 'amount_paid' => invoice['amount_due'])
    assert_equal 'attention', n2_service.call['phase']
    assert_equal before, n2_row.receipt
    refute Toybaco::GrowthPostingStop.where(account_id: @account.id).exists?
  end

  def test_n2_source_and_selection_are_reread_inside_stop_transaction
    n2_fixture
    n2_prepare_only
    before = n2_row.receipt.deep_dup
    original = N2::PostingStop.method(:new)
    account = @account
    factory = lambda do |*args, **kwargs|
      # Direct SQL fault injection bypasses the new coordinator writer fence.
      account.reload.update_columns(internal_attributes: account.internal_attributes.merge(N2::RetentionSnapshot::KEY => { 'different' => true }))
      original.call(*args, **kwargs)
    end
    N2::PostingStop.stub(:new, factory) { assert_equal 'attention', n2_service.call['phase'] }
    assert_equal before, n2_row.receipt
    refute Toybaco::GrowthPostingStop.where(account_id: @account.id).exists?
  end

  def test_n2_new_started_commit_between_intent_and_stop_is_seen_and_retained
    n2_fixture
    n2_prepare_only
    execution = nil
    original = N2::PostingStop.method(:new)
    test = self
    factory = lambda do |*args, **kwargs|
      thread = Thread.new { Account.connection_pool.with_connection { service = test.n2_execution_service; service.prepare!; execution = service.start! } }
      raise 'worker timeout' unless thread.join(5)
      thread.value
      original.call(*args, **kwargs)
    end
    N2::PostingStop.stub(:new, factory) { assert_equal 'waiting', n2_service.call['phase'] }
    assert_equal ['started', true], execution.values_at('state', 'execute')
    assert_equal 'pending', Toybaco::GrowthPostingStop.find_by!(account_id: @account.id).state
  end

  def test_n2_same_n1_cannot_be_rearmed_and_corruption_is_not_history
    n2_fixture
    n2_service.call
    row = n2_row
    assert_raises(ActiveRecord::RecordNotUnique) { CoordinatorRow.create!(row.attributes.except('id')) }
    CoordinatorRow.where(id: row.id).update_all(receipt_hash: 'a' * 64)
    assert_raises(N2::RenewalCoordinatorRecord::Invalid) { n2_service.call }
    assert_equal 'pending', Toybaco::GrowthPostingStop.find_by!(account_id: @account.id).state
  end

  def test_n2_pending_local_change_or_flag_off_intent_cannot_add_stop
    n2_fixture
    attrs = @account.reload.internal_attributes.deep_dup
    @account.update!(internal_attributes: attrs.merge('toybaco_plan_change' => { 'status' => 'pending' }))
    assert_raises(N2::RenewalCoordinatorRecord::Changed) { n2_service.call }
    @account.update!(internal_attributes: attrs)
    n2_prepare_only
    result = n2_service(environment: { 'TOYBACO_RENEWAL_SETTLEMENT_ENABLED' => 'false' }).call
    assert_equal ['prepared', false], result.values_at('phase', 'execute')
    refute Toybaco::GrowthPostingStop.where(account_id: @account.id).exists?
  end

  def test_n2_first_fact_revision_change_cannot_retime_a_saved_operation
    n2_fixture
    n2_prepare_only
    before = n2_row.receipt.deep_dup
    # A mismatched persisted deadline is corruption, never a new seven days.
    @n2_operation.update!(first_failed_at: @n2_operation.first_failed_at + 1, due_at: @n2_operation.due_at + 1)
    assert_equal 'attention', n2_service.call['phase']
    assert_equal before, n2_row.receipt
    refute Toybaco::GrowthPostingStop.where(account_id: @account.id).exists?
  end

  def test_n2_account_delete_retains_receipt_and_permanent_capability
    n2_fixture
    n2_service.call
    row = n2_row
    # Fixture direct deletion proves the table has no Account cascade. Normal
    # Account callbacks deliberately retain the unresolved stop fence.
    @account.delete
    assert @account.destroyed?
    assert_equal row.receipt, row.reload.receipt
    CoordinatorRow.where(id: row.id).delete_all
    assert_equal true, Account.connection.select_value("SELECT EXISTS (SELECT 1 FROM toybaco_durable_capability_acceptances WHERE capability='renewal-settlement-v1')")
    assert_raises(ActiveRecord::StatementInvalid) { Account.connection.execute("DELETE FROM toybaco_durable_capability_acceptances WHERE capability='renewal-settlement-v1'") }
  end
end
