# frozen_string_literal: true

require Rails.root.join('lib/toybaco/growth/posting_paid_upgrade')

module ToybacoPostingPaidUpgradeRuntimeCases
  Paid=Toybaco::Growth::PostingPaidUpgrade
  PaidRow=Toybaco::GrowthPostingPaidUpgrade
  PaidProtocol=Toybaco::Growth::PostingPaidUpgradeProtocol
  PreparationRecord=Toybaco::Growth::PostingPreparationRecord
  PreparationProtocol=Toybaco::Growth::PostingPreparationProtocol
  NOW=Time.utc(2026, 10, 11, 12)
  def teardown
    PaidRow.where(account_id: @account.id).delete_all if @account
    super
  end

  def paid_activate_fixture
    activate_fixture
    paid_target_fixture
  end

  def paid_execution_fixture
    input=execution_fixture
    paid_target_fixture
    input
  end

  def paid_target_fixture
    @old_contract=@account.reload.internal_attributes.fetch('toybaco_contract').deep_dup
    @subscription=JSON.parse(JSON.generate(paid_upgrade_subscription(plan: 'pro')))
    @new_contract=Toybaco::SubscriptionSync.new(client: nil).resolve(@subscription, previous: @old_contract)
  end

  def paid_service(transport = nil, env: nil)
    test=self; client=Object.new
    client.define_singleton_method(:retrieve_subscription) do |_id|
      raise 'Stripe in transaction' if Account.connection.transaction_open?

      test.instance_variable_get(:@subscription).deep_dup
    end
    Paid.new(@account, @owner, client: client, environment: env||authority_environment.merge('TOYBACO_POSTING_PAID_UPGRADE_ENABLED'=>'true'), clock: -> {
      NOW
    }, transport: transport||method(:paid_response))
  end

  def paid_response(payload)
    raise 'HTTP inside transaction' if Account.connection.transaction_open?

    input=payload['handoff']; operation=payload['operation']; @paid_remote||={}; old=@paid_remote[input['operationId']]
    unless old
      raise unless operation=='prepare'

      old={ 'operationId' => input['operationId'], 'requestHash'=>PreparationRecord.digest(input), 'receiptHash'=>'f'*64, 'rootManifestHash'=>'e'*64,
            'state' => 'pending', 'authorityId'=>nil, 'authorityHash'=>nil, 'pointerHash'=>input['expectedPointerHash'], 'current'=>false, 'execute'=>false };

      @paid_remote[input['operationId']]=old
    end
    if operation=='apply' && old['state']=='pending'
      row=Toybaco::GrowthPostingAuthority.find_by!(authority_id: payload['application']['authorityId']);
      orig=Toybaco::Growth::PostingAuthorityRecord.preparation!(row, now: NOW);
      config=PreparationProtocol.configuration(authority_environment);
      ack=Toybaco::Growth::PostingPreparationAck.find(orig, PreparationProtocol.request(orig, @account.id, config: config, now: NOW), now: NOW);
      wire=Toybaco::Growth::PostingAuthorityRecord.wire(row, ack, now: NOW)
      old.merge!('state' => 'applied', 'authorityId'=>row.authority_id, 'authorityHash'=>PreparationRecord.digest(wire), 'pointerHash'=>'1'*64,
                 'current' => true)
    elsif operation=='confirm'; old['state']='ready'
    elsif operation=='withdraw'; old['state']='withdrawn'
    end
    { 'version'=>1, 'request_sha256'=>Digest::SHA256.hexdigest(JSON.generate(payload)), 'handoff'=>old.deep_dup }
  end

  def test_paid_upgrade_roundtrip_uses_actual_contract_principal_and_new_immutable_authority
    paid_activate_fixture
    old=Toybaco::GrowthPostingAuthority.first.receipt.deep_dup; principal=Toybaco::GrowthPostingPrincipal.first.attributes
    result=paid_service.call(operation_id: '9'*64)
    assert_equal 'ready', result['state']; refute result['execute']; assert result['current']
    assert_equal @new_contract, @account.reload.internal_attributes['toybaco_contract']
    assert_equal old, Toybaco::GrowthPostingAuthority.first.receipt
    assert_operator Toybaco::GrowthPostingPrincipal.first.generation, :>, principal['generation']
    assert_equal 2, Toybaco::GrowthPostingAuthority.count
    assert_equal result, paid_service.call(operation_id: '9'*64)
  end
  %w[prepare apply confirm].each do |phase|
    define_method("test_paid_upgrade_#{phase}_commit_response_loss_replays_same_operation") do
      paid_activate_fixture
      failed=false; calls=[]
      transport=->(p) {
        calls<<p.deep_dup; response=paid_response(p); if p['operation']==phase&&!failed; failed=true; raise Timeout::Error; end; response
      }
      svc=paid_service(transport)
      assert_raises(Timeout::Error) { svc.call(operation_id: '8'*64) }
      row=PaidRow.first
      assert_equal({ 'prepare'=>'pending', 'apply'=>'applied', 'confirm'=>'active' }[phase], row.state)
      assert_raises(Toybaco::Growth::PostingExecutionContext::Busy) { Toybaco::Growth::PostingExecutionContext.guard_pending!(@account.id) }
      assert_equal 'ready', svc.call(operation_id: '8'*64)['state']
      same=calls.select { |p| p['operation']==phase }; assert_equal same.first, same.last
      assert_equal 1, PaidRow.count; assert_equal 2, Toybaco::GrowthPostingAuthority.count
    end
  end
  def test_paid_upgrade_after_contract_write_failure_rolls_back_contract_principal_and_pointer
    paid_activate_fixture
    before=@account.reload.attributes;
    principal=Toybaco::GrowthPostingPrincipal.first.attributes; pointer=Toybaco::GrowthPostingAuthorityCurrent.first.attributes
    svc=paid_service; svc.define_singleton_method(:persist_target!) { |*| raise 'fault after contract update' }
    assert_raises(RuntimeError) { svc.call(operation_id: '8'*64) }
    assert_equal 'prepared', PaidRow.first.state
    assert_equal before, @account.reload.attributes
    assert_equal principal, Toybaco::GrowthPostingPrincipal.first.attributes
    assert_equal pointer, Toybaco::GrowthPostingAuthorityCurrent.first.attributes
    assert_equal 1, Toybaco::GrowthPostingAuthority.count
    assert_equal 'ready', paid_service.call(operation_id: '8'*64)['state']
  end

  def test_paid_upgrade_pending_fences_account_membership_and_stop_with_flags_disabled
    paid_activate_fixture
    svc=paid_service(->(p) { raise Timeout::Error })
    assert_raises(Timeout::Error) { svc.call(operation_id: '8'*64) }
    assert_raises(Toybaco::Growth::PostingExecutionContext::Busy) {
      @account.update!(internal_attributes: @account.internal_attributes.merge('toybaco_subscription_id'=>'sub_other'))
    }
    assert_raises(Toybaco::Growth::PostingExecutionContext::Busy) {
      AccountUser.find_by!(account_id: @account.id, user_id: @owner.id).update!(role: 'agent')
    }
    assert_raises(Toybaco::Growth::PostingExecutionContext::Busy) { Toybaco::Growth::PostingStopContext.guard_admission!(@account.id) }
    assert_equal 'pending', PaidRow.first.state
    assert_equal 'administrator', AccountUser.find_by!(account_id: @account.id, user_id: @owner.id).role
  end

  def test_paid_upgrade_prepare_mismatch_leaves_old_current_and_never_applies
    paid_activate_fixture; before=@account.reload.attributes
    svc=paid_service(->(p) { v=paid_response(p); v['handoff']['requestHash']='0'*64; v })
    assert_raises(PreparationRecord::Invalid) { svc.call(operation_id: '8'*64) }
    assert_equal 'pending', PaidRow.first.state; assert_equal before, @account.reload.attributes
    assert_equal 'a'*64, Toybaco::GrowthPostingAuthorityCurrent.first.authority_id
  end

  def test_paid_upgrade_rejects_partial_payment_new_period_and_lower_rank
    paid_activate_fixture
    original=@subscription.deep_dup
    [->(s) { s['latest_invoice']['amount_paid']=1 }, ->(s) { s['items']['data'][0]['current_period_end']+=1 }, ->(s) {
      s['items']['data'][0]['price'].merge!('id'=>'price_light', 'unit_amount'=>9800, 'metadata'=>{ 'toybaco_plan'=>'light', 'toybaco_plan_version'=>'2026-09-25.1' })
    }].each do |mutate|
      @subscription=original.deep_dup; mutate.call(@subscription)
      assert_raises(StandardError) { paid_service.call(operation_id: '8'*64) }
      assert_equal 0, PaidRow.count
    end
  end

  def test_paid_upgrade_disabled_admission_and_outer_transaction_reject_without_journal
    paid_activate_fixture
    assert_raises(PreparationRecord::Invalid) { paid_service(nil, env: authority_environment).call(operation_id: '8'*64) }
    assert_raises(PreparationRecord::Invalid) { Account.transaction { paid_service.call(operation_id: '8'*64) } }
    assert_equal 0, PaidRow.count
  end

  def test_paid_upgrade_confirm_recovery_with_admission_flags_off
    paid_activate_fixture; failed=false
    transport=->(p) { r=paid_response(p); if p['operation']=='confirm'&&!failed; failed=true; raise Timeout::Error; end; r }
    assert_raises(Timeout::Error) { paid_service(transport).call(operation_id: '8'*64) }
    disabled=authority_environment.merge('TOYBACO_POSTING_RELEASE_ENABLED' => 'false', 'TOYBACO_POSTING_AUTHORITY_ENABLED'=>'false',
                                         'TOYBACO_POSTING_PAID_UPGRADE_ENABLED' => 'false')
    assert_equal 'ready', paid_service(transport, env: disabled).call(operation_id: '8'*64)['state']
  end

  def test_paid_upgrade_withdraw_preserves_source_and_durable_marker_survives_journal_delete
    paid_activate_fixture; before=@account.reload.attributes
    assert_raises(Timeout::Error) { paid_service(->(p) { paid_response(p); raise Timeout::Error }).call(operation_id: '8'*64) }
    assert_equal 'withdrawn', paid_service.withdraw!(operation_id: '8'*64)['state']
    assert_equal before, @account.reload.attributes
    assert_equal 'a'*64, Toybaco::GrowthPostingAuthorityCurrent.first.authority_id
    PaidRow.delete_all
    assert_equal 1,
                 Account.connection.select_value("SELECT count(*) FROM toybaco_durable_capability_acceptances WHERE capability='posting-paid-upgrade-v1'").to_i
  end

  def test_paid_upgrade_signed_response_rejects_wrong_direction_stale_signature_and_body_change
    paid_activate_fixture
    assert_raises(Timeout::Error) { paid_service(->(p) { raise Timeout::Error }).call(operation_id: '8'*64) }
    cfg=PaidProtocol.configuration(authority_environment);
    payload=PaidProtocol.request(PaidRow.first.receipt['handoff'], operation: 'prepare', config: cfg)
    raw=JSON.generate(paid_response(payload)); header=PaidProtocol.signature(raw, key: cfg[:key], now: NOW, direction: 'RESPONSE')
    assert_equal JSON.parse(raw), PaidProtocol.response!(raw, header: header, key: cfg[:key], now: NOW, request: payload)
    ['REQUEST', 'RESPONSE'].each do |direction|
      time=direction=='REQUEST' ? NOW : NOW-61
      bad=PaidProtocol.signature(raw, key: cfg[:key], now: time, direction: direction)
      assert_raises(PreparationRecord::Invalid) { PaidProtocol.response!(raw, header: bad, key: cfg[:key], now: NOW, request: payload) }
    end
    assert_raises(PreparationRecord::Invalid) { PaidProtocol.response!(raw+' ', header: header, key: cfg[:key], now: NOW, request: payload) }
  end

  def paid_execution_input(old, result, step: 'COMMENT')
    row=Toybaco::GrowthPostingAuthority.find_by!(authority_id: result['authority_id'])
    old.merge('authorityId' => row.authority_id, 'authorityHash'=>row.postiz_receipt['authorityHash'], 'railsAuthorityHash'=>row.receipt['receipt_hash'],
              'step' => step, 'stepPostId'=>step=='MAIN' ? old['rootId'] : 'child', 'reservationHash'=>'7'*64)
  end

  def test_paid_upgrade_published_main_can_continue_exact_comment_without_restarting_main
    input=paid_execution_fixture; start_execution(input); execution_service(input).result!(outcome: 'published', evidence_hash: 'f'*64)
    result=paid_service.call(operation_id: '8'*64)
    child=paid_execution_input(input, result)
    assert_raises(Toybaco::Growth::InboxReleaseRecord::Invalid) { start_execution(child) }
    assert_equal 1, Toybaco::GrowthPostingExecution.count
    @release_provider.sub = @subscription.deep_dup
    assert_equal 'started', start_execution(child)['state']
    assert_equal 'completed', execution_service(input).status['state']
    assert_equal 2, Toybaco::GrowthPostingExecution.count
    assert_raises(PreparationRecord::Invalid) { start_execution(paid_execution_input(input, result, step: 'MAIN')) }
  end

  def test_paid_upgrade_started_uncertain_and_pending_execution_keep_old_contract_fenced
    input=paid_execution_fixture; start_execution(input)
    %w[started uncertain pending].each do |state|
      execution_service(input).result!(outcome: state, evidence_hash: 'f'*64) unless state=='started'
      assert_raises(Toybaco::Growth::PostingExecutionContext::Busy) { paid_service.call(operation_id: '8'*64) }
      assert_equal 0, PaidRow.count
    end
  end

  def test_paid_upgrade_not_sent_main_is_never_rearmed_by_new_authority
    input=paid_execution_fixture; start_execution(input); execution_service(input).result!(outcome: 'not_sent', evidence_hash: 'f'*64)
    result=paid_service.call(operation_id: '8'*64)
    assert_raises(PreparationRecord::Invalid) { start_execution(paid_execution_input(input, result, step: 'MAIN')) }
    assert_equal 'not_sent', execution_service(input).status['outcome']
  end

  def test_paid_upgrade_vector_matches_existing_typescript_purpose_and_raw_bytes
    vector=JSON.parse(File.read(File.join(__dir__, 'fixtures/posting-authority-protocol-v1.json')))['paidUpgrade']
    raw=vector['raw']; key=OpenSSL::HMAC.digest('SHA256', vector['fixtureSecret'], PaidProtocol::PURPOSE)
    assert_equal vector['requestHash'], PreparationRecord.digest(vector['handoff'])
    assert_equal vector['signature'], PaidProtocol.signature(raw, key: key, now: Time.at(vector['stamp'].to_i), direction: 'POST')
    envelope=JSON.parse(raw); config={ issuer: envelope['issuer'], origin: envelope['audience'], mode: envelope['mode'] }
    assert_equal raw, JSON.generate(PaidProtocol.request(vector['handoff'], operation: 'prepare', config: config))
  end
end
