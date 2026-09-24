# frozen_string_literal: true

module ToybacoPostingPaidUpgradeInventoryCases
  PreparationRecord = Toybaco::Growth::PostingPreparationRecord
  def paid_reader_database
    db = reader_database
    org = @reader_request.fetch('organizationId')
    digest = PreparationRecord.method(:digest)
    original = JSON.parse(db.exec('SELECT payload FROM "ToybacoPostingAuthority"').getvalue(0, 0))
    original.merge!('accountId' => @account.id, 'railsAuthorityHash' => 'a' * 64, 'expiresAt' => self.class::NOW.to_i + 3600,
                    'scheduledPostsPerAccount' => 100, 'expectedPointerHash' => nil)
    original_hash = digest.call(original)
    db.exec_params('UPDATE "ToybacoPostingAuthority" SET payload=$1::jsonb,"authorityHash"=$2', [JSON.generate(original), original_hash])
    schedule = JSON.parse(db.exec('SELECT payload FROM "ToybacoPostingSchedule"').getvalue(0, 0))
    schedule['authorityHash'] = original_hash
    schedule_hash = digest.call(schedule)
    db.exec_params('UPDATE "ToybacoPostingSchedule" SET payload=$1::jsonb,"scheduleHash"=$2', [JSON.generate(schedule), schedule_hash])
    request = Toybaco::Growth::PostingPaidUpgradeProtocol::HANDOFF_FIELDS.to_h { |key| [key, 'd' * 64] }
    request.merge!('accountId' => @account.id, 'organizationId' => org, 'sourceAuthorityId' => original['authorityId'],
                   'sourceAuthorityHash' => original_hash, 'sourcePrincipalHash' => @reader_request['principalHash'],
                   'sourceBindingHash' => @reader_request['contractHash'], 'targetBindingHash' => '7' * 64,
                   'selectionHash' => digest.call(@reader_request['keepIntegrationIds']), 'sourceRank' => 2, 'targetRank' => 3,
                   'sourcePostingLimit' => 6, 'targetPostingLimit' => 12, 'sourceScheduledLimit' => 100, 'targetScheduledLimit' => 300,
                   'expiresAt' => original['expiresAt'])
    root = { 'rootId' => 'reader-root', 'rootGeneration' => @reader_generation, 'scheduleHash' => schedule_hash,
             'saveRequestId' => schedule['saveRequestId'], 'postPayloadHash' => schedule['postPayloadHash'],
             'markerHash' => 'c' * 64, 'state' => 'QUEUE', 'descendantsHash' => 'b' * 64 }
    receipt = { 'version' => 1, 'organizationId' => org, 'operationId' => request['operationId'],
                'requestHash' => digest.call(request), 'roots' => [root], 'rootManifestHash' => digest.call([root]) }
    app = { 'receiptHash' => digest.call(receipt), 'contractAppliedHash' => '5' * 64, 'targetPrincipalHash' => '8' * 64,
            'authorityId' => '6' * 64, 'railsAuthorityHash' => '9' * 64 }
    target = original.merge('authorityId' => app['authorityId'], 'railsAuthorityHash' => app['railsAuthorityHash'],
                            'expectedPointerHash' => request['expectedPointerHash'], 'scheduledPostsPerAccount' => request['targetScheduledLimit'],
                            'kind' => 'paid_upgrade', 'operationId' => request['operationId'], 'sourceAuthorityId' => original['authorityId'],
                            'sourceAuthorityHash' => original_hash, 'handoffReceiptHash' => app['receiptHash'],
                            'contractAppliedHash' => app['contractAppliedHash'], 'targetPrincipalHash' => app['targetPrincipalHash'])
    db.exec('CREATE TEMP TABLE "ToybacoPostingPaidUpgrade" ("organizationId" text,"operationId" text,"requestHash" text,request jsonb,"receiptHash" text,receipt jsonb,"applicationHash" text,application jsonb,state text)')
    db.exec('CREATE TEMP TABLE "ToybacoPostingScheduleContinuation" ("organizationId" text,"rootId" text,"rootGeneration" text,"targetAuthorityId" text,payload jsonb,"continuationHash" text)')
    db.exec_params('INSERT INTO "ToybacoPostingPaidUpgrade" VALUES ($1,$2,$3,$4::jsonb,$5,$6::jsonb,$7,$8::jsonb,$9)',
                   [org, request['operationId'], digest.call(request), JSON.generate(request), digest.call(receipt), JSON.generate(receipt),
                    digest.call(app), JSON.generate(app), 'ready'])
    db.exec_params('INSERT INTO "ToybacoPostingAuthority" VALUES ($1,$2,$3,$4::jsonb)',
                   [org, target['authorityId'], digest.call(target), JSON.generate(target)])
    db.exec_params('UPDATE "ToybacoPostingAuthorityCurrent" SET "authorityId"=$1,generation=2', [target['authorityId']])
    edge = root.merge('organizationId' => org, 'operationId' => request['operationId'], 'handoffReceiptHash' => app['receiptHash'],
                      'sourceAuthorityId' => original['authorityId'], 'sourceAuthorityHash' => original_hash,
                      'targetAuthorityId' => target['authorityId'], 'targetAuthorityHash' => digest.call(target))
    db.exec_params('INSERT INTO "ToybacoPostingScheduleContinuation" VALUES ($1,$2,$3,$4,$5::jsonb,$6)',
                   [org, root['rootId'], root['rootGeneration'], target['authorityId'], JSON.generate(edge), digest.call(edge)])
    @paid_reader_change&.call(db)
    @preparation_read_checks.clear
    db
  end

  def paid_reader_source(context = @reader_context.merge('principalHash' => '8' * 64, 'contractHash' => '7' * 64))
    Toybaco::Growth::PostingReleaseSource.new(@account, connector: -> { paid_reader_database }).read(owner_id: @owner.id, authority_context: context)
  end

  def test_paid_upgrade_reader_links_immutable_old_schedule_to_new_current_context
    reader_fixture
    result = paid_reader_source
    assert_equal @reader_request['identityHash'], result['identity_hash']
    assert @preparation_read_checks.all? { |value| value == ['on', 'repeatable read'] }
    refute JSON.generate(result).include?('fixture body')
    assert_raises(Toybaco::Growth::RetentionPlan::Invalid) { paid_reader_source(@reader_context) }
  end

  def test_paid_upgrade_reader_rejects_missing_corrupt_or_pending_handoff_and_root_edge
    reader_fixture
    ['DELETE FROM "ToybacoPostingScheduleContinuation"', 'DELETE FROM "ToybacoPostingPaidUpgrade"',
     'UPDATE "ToybacoPostingPaidUpgrade" SET state=\'applied\'',
     'UPDATE "ToybacoPostingScheduleContinuation" SET "continuationHash"=repeat(\'0\',64)',
     'UPDATE "ToybacoPostingPaidUpgrade" SET "applicationHash"=repeat(\'0\',64)'].each do |sql|
      @paid_reader_change = ->(db) { db.exec(sql) }
      assert_raises(Toybaco::Growth::RetentionPlan::Invalid) { paid_reader_source }
    end
  end
end
