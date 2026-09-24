# frozen_string_literal: true

require Rails.root.join('lib/toybaco/growth/renewal_dispatch_execution')

module ToybacoGrowthRenewalDispatchPostingCases
  Growth = Toybaco::Growth

  def teardown
    if @dispatch_posting_used
      ids = Toybaco::RenewalOperation.where(subscription_id: @n3_subscription_id).pluck(:id)
      Toybaco::GrowthRenewalDispatch.where(renewal_operation_id: ids).delete_all
      @dispatch_old_flag.nil? ? ENV.delete(Growth::RenewalDispatch::FLAG) : ENV[Growth::RenewalDispatch::FLAG] = @dispatch_old_flag
    end
    super
  end

  def dispatch_posting_fixture
    @dispatch_old_flag = ENV[Growth::RenewalDispatch::FLAG]
    ENV[Growth::RenewalDispatch::FLAG] = 'true'
    @dispatch_posting_used = true
    input, operation = n3i_fixture
    [input, operation, Toybaco::GrowthRenewalDispatch.find_by!(renewal_operation_id: operation.id)]
  end

  def dispatch_posting_run(row, transport: n3i_transport)
    environment = authority_environment.merge('TOYBACO_POSTING_RENEWAL_ENABLED' => 'true')
    worker = Growth::RenewalDispatchWork.new(row, client: n3i_client, environment: environment, clock: -> { n3_now },
                                                transport: transport, connector: -> { preparation_database })
    Growth::RenewalDispatchExecution.new(row, client: n3i_client, environment: environment, clock: -> { n3_now }, worker: worker).call
  end

  def test_dispatch_posting_n3_ready_precedes_sync_and_preserves_original_authority
    input, operation, row = dispatch_posting_fixture
    original = Toybaco::GrowthPostingAuthority.find_by!(authority_id: input['authorityId']).attributes.deep_dup
    request = Growth::RenewalDispatch.request_id(operation, 'renewal_grace')
    assert_equal 'idle', dispatch_posting_run(row)
    continuation = Toybaco::GrowthPostingRenewal.find_by!(request_id: request)
    assert_equal ['grace_ready', 'ready'], [row.reload.phase, continuation.state]
    assert_equal continuation.target_authority_id, Toybaco::GrowthPostingAuthorityCurrent.find_by!(account_id: @account.id).authority_id
    assert_equal original, Toybaco::GrowthPostingAuthority.find_by!(authority_id: input['authorityId']).attributes
    refute Growth::RenewalDispatch.blocked?('test', operation.subscription_id, now: n3_now)
  end

  def test_dispatch_posting_response_loss_and_disabled_dispatch_recover_same_n3
    _, operation, row = dispatch_posting_fixture
    lost = false
    transport = n3i_transport do |payload, _|
      if payload['phase'] == 'confirm' && !lost
        lost = true
        raise Timeout::Error
      end
    end
    assert_equal 'pending', dispatch_posting_run(row, transport: transport)
    request = Growth::RenewalDispatch.request_id(operation, 'renewal_grace')
    continuation = Toybaco::GrowthPostingRenewal.find_by!(request_id: request)
    assert_equal 'applied', continuation.state
    assert Growth::RenewalDispatch.blocked?('test', operation.subscription_id, now: n3_now)
    pointer = Toybaco::GrowthPostingAuthorityCurrent.find_by!(account_id: @account.id).attributes
    ENV[Growth::RenewalDispatch::FLAG] = 'false'
    n3_time(n3_now.to_i + 31)
    assert_equal 'idle', dispatch_posting_run(row, transport: transport)
    assert_equal pointer, Toybaco::GrowthPostingAuthorityCurrent.find_by!(account_id: @account.id).attributes
    assert_equal 1, Toybaco::GrowthPostingRenewal.where(account_id: @account.id, request_id: request).count
  end
end
