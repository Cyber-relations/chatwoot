# frozen_string_literal: true

require Rails.root.join('lib/toybaco/growth/posting_paid_upgrade')

module ToybacoPostingPaidRenewalRuntimeCases
  Paid = Toybaco::Growth::PostingPaidUpgrade
  PaidRow = Toybaco::GrowthPostingPaidUpgrade
  PaidRecord = Toybaco::Growth::PostingPaidUpgradeRecord
  Hashing = Toybaco::Growth::PostingPreparationRecord

  def paid_renewal_current(kind: 'renewal_paid')
    input, operation = n3i_fixture(paid: kind == 'renewal_paid')
    prepared = n3i_prepare(input, operation, kind: kind)
    transport = n3i_transport { |_, response| response.merge!('receiptHash' => '6' * 64, 'rootManifestHash' => '5' * 64) }
    result = n3i_service(transport: transport).deliver!(request_id: prepared['request_id'])
    [input, Toybaco::GrowthPostingAuthority.find_by!(authority_id: result['target_authority_id'])]
  end

  def paid_renewal_target(plan: 'pro')
    value = @n3_provider.deep_dup
    terms = Toybaco::PlanCatalog.default.definition(plan, '2026-09-25.1')
    item = value['items']['data'].first
    item['price'] = { 'id' => "price_mixed#{plan}", 'currency' => 'jpy',
                      'unit_amount' => terms.fetch('cycles').fetch('month').fetch('amount'),
                      'recurring' => { 'interval' => 'month', 'interval_count' => 1 },
                      'metadata' => { 'toybaco_plan' => plan, 'toybaco_plan_version' => '2026-09-25.1' } }
    invoice = value['latest_invoice']
    invoice.merge!('id' => "in_mixed#{plan}", 'billing_reason' => 'subscription_update', 'status' => 'paid',
                   'amount_due' => 10_000, 'amount_paid' => 10_000, 'amount_remaining' => 0)
    invoice['status_transitions']['paid_at'] = n3_now.to_i
    invoice['lines']['data'].first.merge!('price' => { 'id' => item['price']['id'] }, 'proration' => true, 'amount' => 10_000)
    value['status'] = 'active'
    @paid_renewal_provider = value
  end

  def paid_renewal_adjust_service(service)
    service
  end

  def paid_renewal_service(&hook)
    test = self
    client = Object.new
    client.define_singleton_method(:retrieve_subscription) do |id|
      raise 'Stripe inside Account transaction' if Account.connection.transaction_open?
      raise 'wrong subscription' unless id == test.instance_variable_get(:@n3_subscription_id)

      test.instance_variable_set(:@paid_renewal_provider_reads, test.instance_variable_get(:@paid_renewal_provider_reads).to_i + 1)
      test.instance_variable_get(:@paid_renewal_provider).deep_dup
    end
    service = Paid.new(@account, @owner, client: client,
                       environment: authority_environment.merge('TOYBACO_POSTING_PAID_UPGRADE_ENABLED' => 'true'), clock: -> { n3_now },
                       transport: ->(payload) { result = paid_renewal_response(payload); hook&.call(payload, result); result })
    paid_renewal_adjust_service(service)
  end

  def paid_renewal_response(payload)
    raise 'HTTP inside Account transaction' if Account.connection.transaction_open?

    input = payload.fetch('handoff')
    @paid_renewal_remote ||= {}
    row = @paid_renewal_remote[input['operationId']] ||= {
      'operationId' => input['operationId'], 'requestHash' => Hashing.digest(input), 'receiptHash' => 'd' * 64,
      'rootManifestHash' => 'e' * 64, 'state' => 'pending', 'authorityId' => nil, 'authorityHash' => nil,
      'pointerHash' => input['expectedPointerHash'], 'current' => false, 'execute' => false
    }
    if payload['operation'] == 'apply' && row['state'] == 'pending'
      target = Toybaco::GrowthPostingAuthority.find_by!(authority_id: payload.dig('application', 'authorityId'))
      original = Toybaco::Growth::PostingAuthorityRecord.preparation!(target, now: n3_now)
      protocol = Toybaco::Growth::PostingPreparationProtocol
      request = protocol.request(original, @account.id, config: protocol.configuration(authority_environment), now: n3_now)
      ack = Toybaco::Growth::PostingPreparationAck.find(original, request, now: n3_now)
      wire = Toybaco::Growth::PostingAuthorityRecord.wire(target, ack, now: n3_now)
      row.merge!('state' => 'applied', 'authorityId' => target.authority_id, 'authorityHash' => Hashing.digest(wire),
                  'pointerHash' => 'b' * 64, 'current' => true)
    elsif payload['operation'] == 'confirm'
      row['state'] = 'ready'
    end
    { 'version' => 1, 'request_sha256' => Digest::SHA256.hexdigest(JSON.generate(payload)), 'handoff' => row.deep_dup }
  end

  def test_paid_renewal_current_paid_period_is_the_strict_upgrade_source
    _, source = paid_renewal_current
    original = source.attributes.deep_dup
    paid_renewal_target
    result = paid_renewal_service.call(operation_id: '7' * 64)
    target = Toybaco::GrowthPostingAuthority.find_by!(authority_id: result['authority_id'])
    effective = Toybaco::Growth::PostingAuthorityRecord.effective_preparation!(target, now: n3_now)
    assert_equal 'ready', result['state']
    assert_equal original, source.reload.attributes
    assert_equal source.authority_id, target.receipt['source_authority_id']
    assert_equal source.receipt['expires_at'], target.receipt['expires_at']
    assert_equal @n3_boundary, effective.dig('binding', 'coverage', 'term_start')
    assert_equal 'pro', effective.dig('binding', 'contract', 'plan_id')
    assert_operator @paid_renewal_provider_reads, :>=, 3
  end

  def test_paid_renewal_grace_never_admits_upgrade_even_if_next_fetch_would_be_paid
    _, source = paid_renewal_current(kind: 'renewal_grace')
    before = @account.reload.attributes
    paid_renewal_target
    assert_raises(Hashing::Invalid) { paid_renewal_service.call(operation_id: '7' * 64) }
    assert_equal 0, @paid_renewal_provider_reads.to_i
    assert_equal 0, PaidRow.count
    assert_equal before, @account.reload.attributes
    assert_equal source.authority_id, Toybaco::GrowthPostingAuthorityCurrent.first.authority_id
  end

  def test_paid_renewal_confirm_response_loss_keeps_same_journal_and_target
    paid_renewal_current
    paid_renewal_target
    failed = false
    service = paid_renewal_service do |payload, _|
      next unless payload['operation'] == 'confirm' && !failed

      failed = true
      raise Timeout::Error
    end
    assert_raises(Timeout::Error) { service.call(operation_id: '7' * 64) }
    target = PaidRow.first.application['authorityId']
    assert_equal 'active', PaidRow.first.state
    assert_raises(Toybaco::Growth::PostingExecutionContext::Busy) { @account.update!(status: :suspended) }
    assert_equal target, service.call(operation_id: '7' * 64)['authority_id']
    assert_equal 1, PaidRow.count
  end

  def test_paid_renewal_prior_period_or_mutated_anchor_is_rejected
    _, source = paid_renewal_current
    paid_renewal_target
    @paid_renewal_provider['items']['data'].first['current_period_start'] -= 1
    assert_raises(Hashing::Invalid) { paid_renewal_service.call(operation_id: '7' * 64) }
    assert_equal 0, PaidRow.count
    Toybaco::GrowthPostingAuthority.where(id: source.id).update_all(receipt: source.receipt.merge('continuation_hash' => '0' * 64))
    assert_raises(Hashing::Invalid) { paid_renewal_service.call(operation_id: '7' * 64) }
    assert_equal 0, PaidRow.count
  end
  def paid_renewal_reader_database
    db = paid_reader_database
    org = @reader_request.fetch('organizationId')
    digest = Hashing.method(:digest)
    base = JSON.parse(db.exec_params('SELECT payload FROM "ToybacoPostingAuthority" WHERE "authorityId"=$1', ['a' * 64]).getvalue(0, 0))
    previous = db.exec('SELECT * FROM "ToybacoPostingPaidUpgrade"').first
    paid = %w[request receipt application].to_h { |key| [key, JSON.parse(previous[key])] }
    root = paid['receipt']['roots'].first
    boundary = self.class::NOW.to_i - 7200
    deadline = boundary + 3600
    anchor = base.merge('authorityId' => '3' * 64, 'railsAuthorityHash' => '4' * 64, 'expectedPointerHash' => '5' * 64,
                        'expiresAt' => deadline, 'kind' => 'renewal_paid', 'operationId' => '6' * 64,
                        'sourceAuthorityId' => base['authorityId'], 'sourceAuthorityHash' => digest.call(base),
                        'handoffReceiptHash' => '7' * 64, 'contractAppliedHash' => @reader_request['contractHash'],
                        'targetPrincipalHash' => @reader_request['principalHash'])
    request = Toybaco::Growth::PostingRenewalInventory::FIELDS.to_h { |key| [key, 'a' * 64] }.merge(
      'version' => 1, 'protocol' => 'toybaco-posting-renewal-v1', 'phase' => 'prepare', 'kind' => 'renewal_paid',
      'organizationId' => org, 'operationId' => anchor['operationId'], 'sourceAuthorityId' => base['authorityId'],
      'sourceAuthorityHash' => digest.call(base), 'targetAuthorityId' => anchor['authorityId'],
      'targetAuthorityHash' => digest.call(anchor), 'handoffReceiptHash' => anchor['handoffReceiptHash'],
      'contractAppliedHash' => anchor['contractAppliedHash'], 'targetPrincipalHash' => anchor['targetPrincipalHash'],
      'sourcePointerHash' => anchor['expectedPointerHash'], 'preparationRequestId' => anchor['preparationRequestId'],
      'expiresAt' => deadline, 'targetAuthority' => anchor, 'execute' => false,
      'sourceTermStart' => boundary - 3600, 'sourceTermEnd' => boundary, 'termStart' => boundary, 'termEnd' => deadline,
      'firstFailedAt' => nil, 'dueAt' => nil, 'planRank' => 2, 'postingAccountLimit' => @reader_request['postingAccountLimit'])
    retained = root.merge('originalAuthorityId' => base['authorityId'], 'originalAuthorityHash' => digest.call(base))
    receipt = { 'version' => 1, 'organizationId' => org, 'operationId' => anchor['operationId'],
                'requestHash' => digest.call(request.except('phase')), 'roots' => [retained],
                'rootManifestHash' => digest.call([retained]), 'targetPointerHash' => 'b' * 64 }
    db.exec('CREATE TEMP TABLE "ToybacoPostingRenewal" ("organizationId" text,"operationId" text,"requestHash" text,request jsonb,"receiptHash" text,receipt jsonb,state text)')
    db.exec_params('INSERT INTO "ToybacoPostingRenewal" VALUES ($1,$2,$3,$4::jsonb,$5,$6::jsonb,$7)',
                   [org, anchor['operationId'], receipt['requestHash'], JSON.generate(request), digest.call(receipt), JSON.generate(receipt), 'ready'])
    db.exec_params('INSERT INTO "ToybacoPostingAuthority" VALUES ($1,$2,$3,$4::jsonb)', [org, anchor['authorityId'], digest.call(anchor), JSON.generate(anchor)])
    edge = retained.merge('kind' => 'renewal_paid', 'organizationId' => org, 'operationId' => anchor['operationId'],
                          'handoffReceiptHash' => digest.call(receipt), 'sourceAuthorityId' => base['authorityId'],
                          'sourceAuthorityHash' => digest.call(base), 'targetAuthorityId' => anchor['authorityId'], 'targetAuthorityHash' => digest.call(anchor))
    db.exec_params('INSERT INTO "ToybacoPostingScheduleContinuation" VALUES ($1,$2,$3,$4,$5::jsonb,$6)',
                   [org, root['rootId'], root['rootGeneration'], anchor['authorityId'], JSON.generate(edge), digest.call(edge)])
    paid_renewal_relink_reader!(db, paid, anchor, root)
    @paid_renewal_reader_fault&.call(db)
    @preparation_read_checks.clear
    db
  end

  def paid_renewal_relink_reader!(db, paid, anchor, root)
    digest = Hashing.method(:digest)
    request, receipt, app = paid.values_at('request', 'receipt', 'application')
    request.merge!('sourceAuthorityId' => anchor['authorityId'], 'sourceAuthorityHash' => digest.call(anchor),
                    'expiresAt' => anchor['expiresAt'], 'expectedPointerHash' => 'b' * 64)
    receipt['requestHash'] = digest.call(request)
    app['receiptHash'] = digest.call(receipt)
    target = anchor.merge('kind' => 'paid_upgrade', 'authorityId' => app['authorityId'], 'railsAuthorityHash' => app['railsAuthorityHash'],
                           'expectedPointerHash' => request['expectedPointerHash'], 'scheduledPostsPerAccount' => request['targetScheduledLimit'],
                           'operationId' => request['operationId'], 'sourceAuthorityId' => anchor['authorityId'], 'sourceAuthorityHash' => digest.call(anchor),
                           'handoffReceiptHash' => app['receiptHash'], 'contractAppliedHash' => app['contractAppliedHash'], 'targetPrincipalHash' => app['targetPrincipalHash'])
    db.exec_params('UPDATE "ToybacoPostingPaidUpgrade" SET "requestHash"=$1,request=$2::jsonb,"receiptHash"=$3,receipt=$4::jsonb,"applicationHash"=$5,application=$6::jsonb',
                   [digest.call(request), JSON.generate(request), app['receiptHash'], JSON.generate(receipt), digest.call(app), JSON.generate(app)])
    db.exec_params('UPDATE "ToybacoPostingAuthority" SET "authorityHash"=$1,payload=$2::jsonb WHERE "authorityId"=$3',
                   [digest.call(target), JSON.generate(target), target['authorityId']])
    edge = root.merge('organizationId' => request['organizationId'], 'operationId' => request['operationId'],
                      'handoffReceiptHash' => app['receiptHash'], 'sourceAuthorityId' => anchor['authorityId'], 'sourceAuthorityHash' => digest.call(anchor),
                      'targetAuthorityId' => target['authorityId'], 'targetAuthorityHash' => digest.call(target))
    db.exec_params('UPDATE "ToybacoPostingScheduleContinuation" SET payload=$1::jsonb,"continuationHash"=$2 WHERE "targetAuthorityId"=$3',
                   [JSON.generate(edge), digest.call(edge), target['authorityId']])
  end

  def paid_renewal_reader_source
    context = @reader_context.merge('principalHash' => '8' * 64, 'contractHash' => '7' * 64)
    Toybaco::Growth::PostingReleaseSource.new(@account, connector: -> { paid_renewal_reader_database }).read(owner_id: @owner.id, authority_context: context)
  end

  def test_paid_renewal_expired_reader_classifies_only_original_schedule_and_both_edges
    reader_fixture
    result = paid_renewal_reader_source
    assert_equal @reader_request['identityHash'], result['identity_hash']
    refute JSON.generate(result).include?('fixture body')
    assert @preparation_read_checks.all? { |item| item == ['on', 'repeatable read'] }
  end

  def test_paid_renewal_reader_missing_renewal_proof_or_either_edge_rejects
    reader_fixture
    ["DELETE FROM \"ToybacoPostingRenewal\"", "UPDATE \"ToybacoPostingRenewal\" SET state='pending'",
     "DELETE FROM \"ToybacoPostingScheduleContinuation\" WHERE \"targetAuthorityId\"=repeat('3',64)",
     "DELETE FROM \"ToybacoPostingScheduleContinuation\" WHERE \"targetAuthorityId\"=repeat('6',64)"].each do |sql|
      @paid_renewal_reader_fault = ->(db) { db.exec(sql) }
      assert_raises(Toybaco::Growth::RetentionPlan::Invalid) { paid_renewal_reader_source }
    end
  end

  def test_paid_renewal_failure_fact_is_retained_and_only_exact_recovery_is_accepted
    _, source = paid_renewal_current
    original = Toybaco::Growth::PostingAuthorityRecord.preparation!(source, now: n3_now)
    prepared = Toybaco::Growth::PostingRenewalAuthority.effective_preparation!(source, original, now: n3_now)
    proof = prepared.fetch('posting_renewal').fetch('recovery')
    attrs = @account.reload.internal_attributes.deep_dup
    key = Toybaco::Growth::RenewalSettlement::FAILURE_KEY
    attrs[key] = proof['failure'].slice('subscription_id', 'invoice_id', 'first_failed_at').merge(
      'grace_ends_at' => proof['failure']['due_at'], 'term_start' => proof['period']['term_start'], 'term_end' => proof['period']['term_end'])
    saved = attrs.deep_dup
    policy = Toybaco::Growth::PostingPaidUpgradeBilling
    refute policy.blocked?(attrs, recovery: proof, environment: authority_environment) { |candidate| candidate.key?(key) }
    assert_equal saved, attrs
    changed = attrs.deep_dup
    changed[key]['invoice_id'] = 'in_foreign'
    assert policy.blocked?(changed, recovery: proof, environment: authority_environment) { |candidate| candidate.key?(key) }
    assert policy.blocked?(attrs, recovery: nil, environment: authority_environment) { |candidate| candidate.key?(key) }
  end
end
