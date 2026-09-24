# frozen_string_literal: true

require Rails.root.join('lib/toybaco/growth/renewal_coordinator_settlement')

module ToybacoRenewalProviderRuntimeCases
  N2 = Toybaco::Growth
  CoordinatorRow = Toybaco::GrowthRenewalCoordinator
  ProviderRow = Toybaco::GrowthRenewalSettlement

  def teardown
    ProviderRow.where(account_id: @account.id).delete_all if @renewal_test_used
    super
  end

  def n2p_fixture
    n2_fixture
    n2_service.call
    @n2p_calls = []
  end

  def n2p_client
    client = n3i_client
    test = self
    client.define_singleton_method(:void_invoice) do |id, idempotency_key:|
      test.n2p_action(:void, id)
      raise 'missing deterministic idempotency key' unless idempotency_key.start_with?('toybaco-renewal-void-')
      test.instance_variable_get(:@n3_provider)['latest_invoice'].merge!('status' => 'void')
      test.instance_variable_get(:@n2p_after_void)&.call
    end
    client.define_singleton_method(:cancel_unpaid_subscription) do |id|
      test.n2p_action(:cancel, id)
      test.instance_variable_get(:@n3_provider)['status'] = 'canceled'
      test.instance_variable_get(:@n2p_after_cancel)&.call
    end
    client.singleton_methods.each do |name|
      method = client.method(name)
      client.define_singleton_method(name) do |*args, **kwargs|
        raise 'provider called inside Account transaction' if Account.connection.transaction_open?
        test.instance_variable_get(:@n2p_before_read)&.call(name)
        method.call(*args, **kwargs)
      end
    end
    client
  end

  def n2p_action(action, id)
    expected = action == :void ? @n3_provider['latest_invoice']['id'] : @n3_subscription_id
    assert_equal expected, id
    @n2p_calls << action
    @n2p_before_action&.call(action)
  end

  def n2p_service(environment: {}, client: n2p_client)
    env = authority_environment.merge('TOYBACO_RENEWAL_SETTLEMENT_ENABLED' => 'true',
                                      'TOYBACO_RENEWAL_PROVIDER_SETTLEMENT_ENABLED' => 'true')
    N2::RenewalCoordinatorSettlement.new(@n2_operation.id, client: client, environment: env.merge(environment), clock: -> { n3_now })
  end

  def n2p_row = ProviderRow.find_by!(coordinator_id: n2_row.id)

  def test_n2p_provider_closure_checkpoints_are_separate_from_free
    n2p_fixture
    before = n2_row.receipt.deep_dup
    assert_equal 'provider_closed', n2p_service.call['phase']
    assert_equal %i[void cancel], @n2p_calls
    assert_equal before, n2_row.receipt
    assert_equal 'provider_closed', @account.reload.internal_attributes[N2::RenewalTransition::KEY]['state']
    assert_equal 'closed', @account.internal_attributes[N2::RenewalSettlement::KEY]['state']
    assert_equal 'pending', Toybaco::GrowthPostingStop.find_by!(account_id: @account.id).state
    refute_equal 'free', Toybaco::Entitlements.contract_for(@account)['plan_id']
    result = n2p_service.call
    assert_equal 'provider_closed', result['phase']
    assert_equal %i[void cancel], @n2p_calls
  end

  def test_n2p_void_amounts_match_stripe_and_inconsistent_remaining_stops_cancel
    n2p_fixture
    invoice = @n3_provider.fetch('latest_invoice')
    @n2p_after_void = -> { invoice['amount_remaining'] = 0 }
    assert_raises(N2::RenewalSettlement::Unresolved) { n2p_service.call }
    assert_equal [:void], @n2p_calls
    assert_equal 'prepared', n2p_row.phase
    assert_equal 'void', invoice['status']
    invoice['amount_remaining'] = invoice.fetch('amount_due')
    @n2p_after_void = nil
    assert_equal 'provider_closed', n2p_service.call['phase']
    assert_equal %i[void cancel], @n2p_calls
    assert_equal invoice.fetch('amount_due'), invoice['amount_remaining']
  end

  def test_n2p_void_commit_with_lost_response_and_read_failure_recovers_without_second_void
    n2p_fixture
    @n2p_after_void = -> { @n2p_before_read = ->(_) { raise IOError, 'fixture read failure after void' }; raise Timeout::Error }
    assert_raises(IOError) { n2p_service.call }
    assert_equal 'prepared', n2p_row.phase
    assert_equal 'prepared', @account.reload.internal_attributes[N2::RenewalTransition::KEY]['state']
    @n2p_after_void = @n2p_before_read = nil
    assert_equal 'provider_closed', n2p_service.call['phase']
    assert_equal %i[void cancel], @n2p_calls
  end

  def test_n2p_cancel_commit_with_lost_response_recovers_same_journal
    n2p_fixture
    @n2p_after_cancel = -> { @n2p_before_read = ->(_) { raise IOError, 'fixture read failure after cancel' }; raise Timeout::Error }
    assert_raises(IOError) { n2p_service.call }
    receipt = n2p_row.receipt.deep_dup
    assert_equal 'invoice_voided', n2p_row.phase
    @n2p_after_cancel = @n2p_before_read = nil
    assert_equal 'provider_closed', n2p_service.call['phase']
    assert_equal receipt, n2p_row.receipt
    assert_equal %i[void cancel], @n2p_calls
  end

  def test_n2p_checkpoint_insert_and_account_journal_roll_back_atomically
    n2p_fixture
    callback = -> { raise IOError, 'fixture after checkpoint' if phase == 'invoice_voided' }
    ProviderRow.set_callback(:update, :after, callback)
    assert_raises(IOError) { n2p_service.call }
    assert_equal 'prepared', n2p_row.phase
    assert_equal 'prepared', @account.reload.internal_attributes[N2::RenewalTransition::KEY]['state']
    assert_equal [:void], @n2p_calls
    ProviderRow.skip_callback(:update, :after, callback)
    callback = nil
    assert_equal 'provider_closed', n2p_service.call['phase']
    assert_equal %i[void cancel], @n2p_calls
  ensure
    ProviderRow.skip_callback(:update, :after, callback) if callback
  end

  def test_n2p_http_has_no_transaction_and_normal_writers_cannot_apply_even_correct_free_target
    n2p_fixture
    @n2p_before_action = lambda do |_|
      Thread.new do
        Account.connection_pool.with_connection do
          current = Account.find(@account.id)
          refute N2::ManagedAuto.eligible?(current)
          assert_raises(N2::PostingExecutionContext::Busy) { current.update!(status: :suspended) }
          current.reload
          attrs = current.internal_attributes.except(N2::PurchaseIntent::KEY, 'toybaco_subscription_id')
          target = Toybaco::Entitlements.project_attributes(attrs, N2::FreeReturnRecord.free_contract)
          assert_equal n2_row.receipt['target_hash'], N2::PostingExecutionContext.digest(N2::PostingExecutionContext.binding('active', target))
          assert_raises(N2::PostingExecutionContext::Busy) { current.update!(internal_attributes: target) }
          current.reload
          assert_raises(N2::PostingExecutionContext::Busy) { current.update!(internal_attributes: current.internal_attributes.merge('toybaco_subscription_status' => 'active')) }
          assert_raises(N2::PostingExecutionContext::Busy) { AccountUser.find_by!(account_id: current.id, user_id: @owner.id).update!(role: :agent) }
        end
      end.value
    end
    assert_equal 'provider_closed', n2p_service.call['phase']
  end

  def test_n2p_unresolved_auto_and_step_wait_without_provider_work_or_lease_completion
    n2_fixture
    execution = n2_execution('uncertain')
    n2_service.call
    @n2p_calls = []
    @n2p_before_read = ->(_) { raise 'must not read provider' }
    assert_equal 'waiting', n2p_service.call['phase']
    n3_time(n3_now.to_i + 365.days.to_i)
    assert_equal 'waiting', n2p_service.call['phase']
    assert_equal 'uncertain', execution.reload.state
    assert_equal 0, ProviderRow.count
  end

  def test_n2p_flag_off_recovery_keeps_fence_and_never_starts_next_mutation
    n2p_fixture
    @n2p_after_void = -> { @n2p_before_read = ->(_) { raise IOError }; raise Timeout::Error }
    assert_raises(IOError) { n2p_service.call }
    @n2p_before_read = @n2p_after_void = nil
    assert_equal 'invoice_voided', n2p_service(environment: { 'TOYBACO_RENEWAL_PROVIDER_SETTLEMENT_ENABLED' => 'false' }).call['phase']
    assert_equal [:void], @n2p_calls
    assert_raises(N2::PostingExecutionContext::Busy) { @account.reload.update!(status: :suspended) }
    assert_equal 'provider_closed', n2p_service.call['phase']
    assert_equal %i[void cancel], @n2p_calls
  end

  def test_n2p_paid_first_is_review_and_never_withdraws_stop_or_recovers_by_status_only
    n2p_fixture
    invoice = @n3_provider['latest_invoice']
    invoice.merge!('status' => 'paid', 'amount_paid' => invoice['amount_due'], 'amount_remaining' => 0)
    assert_equal 'payment_review', n2p_service.call['phase']
    assert_equal 'pending', Toybaco::GrowthPostingStop.find_by!(account_id: @account.id).state
    assert_equal 'prepared', @account.reload.internal_attributes[N2::RenewalTransition::KEY]['state']
    assert_equal [], @n2p_calls
    assert_equal 'payment_review', n2p_service.call['phase']
    assert_raises(N2::PostingExecutionContext::Busy) { @account.reload.update!(status: :suspended) }
  end

  def test_n2p_partial_mixed_invoice_and_shared_customer_never_mutate
    n2p_fixture
    invoice = @n3_provider['latest_invoice'].deep_dup
    @n3_provider['latest_invoice']['amount_paid'] = 1
    assert_raises(N2::RenewalSettlement::Unresolved) { n2p_service.call }
    @n3_provider['latest_invoice'] = invoice.deep_dup
    @n3_provider['latest_invoice']['lines']['data'] << invoice['lines']['data'].first.deep_dup
    assert_raises(N2::RenewalSettlement::Unresolved) { n2p_service.call }
    @n3_provider['latest_invoice'] = invoice
    other = Account.create!(name: 'fixture unrelated', internal_attributes: { 'toybaco_stripe_customer_id' => @n3_customer_id })
    assert_raises(N2::RenewalSettlement::Unresolved) { n2p_service.call }
    assert_equal [], @n2p_calls
  ensure
    Account.where(id: other.id).delete_all if other
  end

  def test_n2p_all_invoice_payments_and_old_intent_must_be_idle
    n2p_fixture
    client = n2p_client
    id = @n3_provider['latest_invoice']['id']
    client.define_singleton_method(:list_invoice_payments) do |_, **|
      { 'data' => [{ 'id' => 'inpay_fixture', 'invoice' => id, 'livemode' => false, 'currency' => 'jpy', 'status' => 'paid' }], 'has_more' => false }
    end
    assert_raises(N2::RenewalSettlement::Unresolved) { n2p_service(client: client).call }
    @n3_provider['latest_invoice']['payment_intent'] = 'pi_old'
    client = n2p_client
    customer = @n3_customer_id
    client.define_singleton_method(:retrieve_payment_intent) do |id|
      { 'id' => id, 'customer' => customer, 'livemode' => false, 'currency' => 'jpy', 'status' => 'processing', 'amount_received' => 0 }
    end
    assert_raises(N2::RenewalSettlement::Unresolved) { n2p_service(client: client).call }
    assert_equal [], @n2p_calls
  end

  def test_n2p_outer_transaction_corrupt_source_and_disabled_new_admission_are_rejected
    n2p_fixture
    @account.with_lock { assert_raises(N2::RenewalCoordinatorRecord::Invalid) { n2p_service.call } }
    assert_equal 'waiting', n2p_service(environment: { 'TOYBACO_RENEWAL_PROVIDER_SETTLEMENT_ENABLED' => 'false' }).call['phase']
    assert_equal 0, ProviderRow.count
    receipt = n2_row.receipt
    CoordinatorRow.where(id: n2_row.id).update_all(receipt: receipt.merge('evidence_hash' => '9' * 64))
    assert_raises(N2::RenewalCoordinatorRecord::Invalid) { n2p_service.call }
    assert_equal [], @n2p_calls
  end
  def n2p_hold_environment
    { 'TOYBACO_POSTING_RETENTION_ENABLED' => 'true', 'TOYBACO_INBOX_RETENTION_ENABLED' => 'true',
      'TOYBACO_GROWTH_FREE_RETURN_ENABLED' => 'true', 'TOYBACO_STRIPE_MODE' => 'test',
      'TOYBACO_POST_URL' => 'https://post.staging.toybaco.jp', 'FRONTEND_URL' => 'https://app.staging.toybaco.jp',
      'TOYBACO_OIDC_CLIENT_SECRET' => 'fixture-only-retention-secret-over-32-characters' }
  end

  def n2p_holds
    keys = [N2::PostingRetention::KEY, N2::InboxRetention::KEY, N2::InboxDeliveryEpoch::KEY, N2::InboxReleaseRecord::KEY, N2::FreeReturnRecord::KEY]
    # This replaces only the earlier synthetic fixture hold baseline. It is not a next-generation hold exchange.
    @account.reload.update_columns(internal_attributes: @account.internal_attributes.except(*keys))
    response = lambda do |payload|
      { 'version' => 1, 'request_sha256' => Digest::SHA256.hexdigest(JSON.generate(payload)),
        'organization_id' => payload['organization_id'], 'transition_id' => payload['transition_id'],
        'policy_hash' => payload['policy_hash'], 'receipt_hash' => 'b' * 64, 'kept_posts' => 0, 'held_posts' => 0 }
    end
    N2::PostingRetention.new(@account.reload, environment: n2p_hold_environment, transport: response, clock: -> { n3_now }).call
    N2::InboxRetention.new(@account.reload, environment: n2p_hold_environment, clock: -> { n3_now }).call
  end

  # The integrated fixture already returned this account to Free once before its
  # paid repurchase. That immutable Free return row and its Free20 grant (revoked
  # by the repurchase) are history, not results of the renewal settlement under
  # test, so assertions compare against them.
  def n2p_free_returns = Toybaco::GrowthFreeReturn.where(account_id: @account.id).order(:id).map(&:attributes)
  def n2p_free_grants = Toybaco::GrowthAiGrant.where(account_id: @account.id, units: 20).order(:id).map(&:attributes)

  def test_n2p_final_free_requires_both_holds_and_applies_stop_with_receipt_and_allowance
    n2p_fixture
    n2p_service.call
    service = n2p_service(environment: n2p_hold_environment)
    assert_raises(N2::RenewalTransition::Changed, N2::RetentionProtocol::Invalid) { service.complete_free! }
    n2p_holds
    history = n2p_free_returns
    grant_history = n2p_free_grants
    assert_equal [1, 1], [history.size, grant_history.size]
    before = @account.reload.internal_attributes.deep_dup
    grant = N2::AiGrants.new(@account).issue!(source: 'pack', source_key: 'pack:settlementfixture', units: 500,
                                           starts_at: n3_now - 1.day, ends_at: n3_now + 80.days)
    grant.update!(used: 12)
    packed = grant.attributes.deep_dup
    manual = Toybaco::GrowthAiOperation.create!(account: @account, grant: grant, kind: 'reply_draft', state: 'reserved',
      request_key: SecureRandom.uuid, context_digest: 'a' * 64, token_digest: 'b' * 64, lease_expires_at: n3_now + 5.minutes)
    manual_before = manual.attributes.deep_dup
    assert_equal 'free_completed', service.complete_free!['phase']
    assert_equal 'free_completed', n2_row.phase
    assert_equal 'applied', Toybaco::GrowthPostingStop.find_by!(account_id: @account.id).state
    assert_equal 'free', Toybaco::Entitlements.contract_for(@account.reload)['plan_id']
    assert before['toybaco_growth_registration'] == @account.internal_attributes['toybaco_growth_registration']
    assert_equal packed, grant.reload.attributes
    assert_equal manual_before, manual.reload.attributes
    free_returns = n2p_free_returns
    assert_equal history, free_returns.first(history.size)
    assert_equal 1, free_returns.size - history.size
    assert_equal @account.internal_attributes.dig(N2::FreeReturnRecord::KEY, 'transition_id'), free_returns.last['transition_id']
    refute_includes history.map { |row| row['transition_id'] }, free_returns.last['transition_id']
    free_grants = n2p_free_grants
    assert_equal grant_history, free_grants.first(grant_history.size)
    assert_equal 1, free_grants.size - grant_history.size
    assert_equal 'free_completed', service.complete_free!['phase']
    assert_equal %i[void cancel], @n2p_calls
  end

  def test_n2p_final_free_grant_failure_rolls_back_contract_stop_journal_and_receipt
    n2p_fixture
    n2p_service.call
    n2p_holds
    history = n2p_free_returns
    grant_history = n2p_free_grants
    assert_equal [1, 1], [history.size, grant_history.size]
    before = @account.reload.attributes.deep_dup
    principal = Toybaco::GrowthPostingPrincipal.where(account_id: @account.id).map(&:attributes)
    hook = -> { raise IOError, 'fixture Free grant insert failure' if units == 20 }
    Toybaco::GrowthAiGrant.set_callback(:create, :after, hook)
    assert_raises(IOError) { n2p_service(environment: n2p_hold_environment).complete_free! }
    assert_equal before, @account.reload.attributes
    assert_equal principal, Toybaco::GrowthPostingPrincipal.where(account_id: @account.id).map(&:attributes)
    assert_equal 'provider_closed', n2p_row.phase
    assert_equal 'stop_recorded', n2_row.phase
    assert_equal 'pending', Toybaco::GrowthPostingStop.find_by!(account_id: @account.id).state
    assert_equal [history, grant_history], [n2p_free_returns, n2p_free_grants]
  ensure
    Toybaco::GrowthAiGrant.skip_callback(:create, :after, hook) if hook
  end

  def test_n2p_shared_debt_pending_items_and_all_subscription_pages_remain_protected
    n2p_fixture
    client = n2p_client
    customer = @n3_customer_id
    client.define_singleton_method(:list_customer_invoices) do |_, **|
      { 'data' => [{ 'id' => 'in_otherdebt', 'customer' => customer, 'livemode' => false, 'status' => 'open' }], 'has_more' => false }
    end
    assert_raises(N2::RenewalSettlement::Unresolved) { n2p_service(client: client).call }
    client = n2p_client
    client.define_singleton_method(:pending_customer_invoice_items) { |_| { 'data' => [{}], 'has_more' => false } }
    assert_raises(N2::RenewalSettlement::Unresolved) { n2p_service(client: client).call }
    client = n2p_client
    client.define_singleton_method(:list_customer_subscriptions) do |_, **|
      { 'data' => [{ 'id' => 'sub_otheractive', 'customer' => customer, 'livemode' => false, 'status' => 'active' }], 'has_more' => false }
    end
    assert_raises(N2::RenewalSettlement::Unresolved) { n2p_service(client: client).call }
    assert_equal [], @n2p_calls
  end

  def test_n2p_unfinished_pack_and_parent_phase_corruption_never_start_provider_mutation
    n2p_fixture
    before = @account.reload.internal_attributes
    @account.update_columns(internal_attributes: before.merge('toybaco_plan_change' => { 'status' => 'pending' }))
    assert_raises(N2::RenewalCoordinatorRecord::Changed) { n2p_service.call }
    @account.update_columns(internal_attributes: before)
    n2_row.update!(phase: 'attention')
    assert_raises(N2::RenewalCoordinatorRecord::Changed) { n2p_service.call }
    assert_equal [], @n2p_calls
  end

  def test_n2p_acceptance_marker_is_permanent_after_source_row_deletion
    n2p_fixture
    n2p_service.call
    assert_equal true, Account.connection.select_value("SELECT EXISTS (SELECT 1 FROM toybaco_durable_capability_acceptances WHERE capability='renewal-provider-settlement-v1')")
    n2p_row.delete
    assert_equal true, Account.connection.select_value("SELECT EXISTS (SELECT 1 FROM toybaco_durable_capability_acceptances WHERE capability='renewal-provider-settlement-v1')")
    assert_raises(ActiveRecord::StatementInvalid) { Account.connection.execute("DELETE FROM toybaco_durable_capability_acceptances WHERE capability='renewal-provider-settlement-v1'") }
    assert_raises(N2::PostingExecutionContext::Busy) { @account.reload.update!(status: :suspended) }
  end

  def test_n2p_unknown_auto_waits_even_after_a_year_and_blocks_fresh_auto_eligibility
    n2_fixture
    unknown = Toybaco::GrowthAutoRequest.create!(account_id: @account.id, inbox_id: 1, installation_id: 1, message_id: 1,
      conversation_id: 1, generation: 1, epoch: SecureRandom.uuid, operation_id: 1, state: 'uncertain', started_at: n3_now, enqueue_after: n3_now)
    n2_service.call
    @n2p_calls = []
    @n2p_before_read = ->(_) { raise 'must not reach provider while AUTO is unresolved' }
    assert_equal 'waiting', n2p_service.call['phase']
    n3_time(n3_now.to_i + 365.days.to_i)
    assert_equal 'waiting', n2p_service.call['phase']
    assert_equal 'uncertain', unknown.reload.state
    refute N2::ManagedAuto.eligible?(@account.reload)
    assert_equal 0, ProviderRow.count
  end

  def test_n2p_fresh_provider_state_must_still_match_saved_closed_checkpoint
    n2p_fixture
    n2p_service.call
    @n3_provider['status'] = 'active'
    assert_raises(N2::RenewalCoordinatorRecord::Invalid) { n2p_service.call }
    assert_equal 'provider_closed', n2p_row.phase
    assert_equal 'pending', Toybaco::GrowthPostingStop.find_by!(account_id: @account.id).state
    assert_equal %i[void cancel], @n2p_calls
  end

end
