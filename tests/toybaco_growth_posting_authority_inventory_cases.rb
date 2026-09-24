# frozen_string_literal: true

require Rails.root.join('lib/toybaco/growth/posting_release_source')

# Actual isolated Postiz PG reads. Billing/provider authority hashes are fixture
# inputs here; current Rails authorization is exercised by the parent services.
module ToybacoPostingAuthorityInventoryCases
  PreparationRecord = Toybaco::Growth::PostingPreparationRecord
  READER_UUID = '11111111-1111-4111-8111-111111111111'

  def reader_fixture(held_root: false)
    prepare_posting_preparation(held_post_ids: held_root ? ['reader-root'] : [])
    snapshot = Toybaco::Growth::PostingReleaseSource.new(@account, connector: -> { preparation_database }).read(owner_id: @owner.id)
    @reader_context = { 'ownerId' => @owner.id, 'actorId' => @owner.id, 'principalHash' => '1' * 64, 'contractHash' => '2' * 64 }
    @reader_request = @reader_context.merge('version' => 2, 'accountId' => @account.id,
      'organizationId' => snapshot['organization_id'], 'requestId' => '3' * 64, 'ownerMembershipId' => snapshot.dig('owner', 'membership_id'),
      'railsReceiptHash' => '4' * 64, 'selectionRevision' => '5' * 64, 'holdTransitionId' => snapshot['transition_id'],
      'holdReceiptHash' => snapshot['receipt_hash'], 'holdGeneration' => snapshot['generation'], 'inventoryHash' => snapshot['inventory_hash'],
      'identityHash' => snapshot['identity_hash'], 'requestedIntegrationIds' => ['channel-a'], 'keepIntegrationIds' => ['channel-a'], 'postingAccountLimit' => 6)
    @reader_generation = "#{(self.class::NOW.to_r * 1000).to_i}:#{READER_UUID}"
  end

  def reader_database
    db = preparation_database
    unless db.exec(%q{SELECT to_regclass('"ToybacoPostingAuthorityCurrent"')}).getvalue(0, 0)
      db.exec('CREATE TEMP TABLE "ToybacoPostingAuthorityCurrent" ("organizationId" text,"authorityId" text,generation bigint,epoch uuid,state text)')
    end
    db.exec('ALTER TABLE "Post" ADD COLUMN error text, ADD COLUMN content text, ADD COLUMN image text, ADD COLUMN settings text, ADD COLUMN delay integer, ADD COLUMN title text, ADD COLUMN description text, ADD COLUMN "intervalInDays" integer, ADD COLUMN "createdAt" timestamp, ADD COLUMN "approvedSubmitForOrder" text, ADD COLUMN "group" text')
    db.exec('CREATE TEMP TABLE "ToybacoPostingAuthority" ("organizationId" text,"authorityId" text,"authorityHash" text,payload jsonb)')
    db.exec('CREATE TEMP TABLE "ToybacoPostingPreparation" ("organizationId" text,"requestId" text,"payloadHash" text,request jsonb,"receiptHash" text,receipt jsonb,"createdAt" timestamp)')
    db.exec('CREATE TEMP TABLE "ToybacoPostingSchedule" ("organizationId" text,"rootId" text,"rootGeneration" text,"authorityId" text,payload jsonb,"scheduleHash" text)')
    db.exec('CREATE TEMP TABLE "ToybacoPostSaveRequest" ("organizationId" text,"actorId" text,"requestId" text,"payloadHash" text,"postsJson" jsonb)')
    org = @reader_request.fetch('organizationId')
    now = self.class::NOW
    wire = @reader_request
    receipt = { 'version' => 2, 'organizationId' => org, 'requestId' => wire['requestId'], 'payloadHash' => PreparationRecord.digest(wire),
      'preparedAt' => (now.to_r * 1000).to_i, 'state' => 'prepared', 'execute' => false }
    receipt['receiptHash'] = PreparationRecord.digest(receipt)
    authority = { 'authorityId' => 'a' * 64, 'organizationId' => org, 'preparationRequestId' => wire['requestId'], 'preparationReceiptHash' => receipt['receiptHash'] }
    db.exec_params(%q{INSERT INTO "ToybacoPostingAuthorityCurrent" VALUES ($1,$2,1,$3,'ready')}, [org, authority['authorityId'], READER_UUID])
    db.exec_params('INSERT INTO "ToybacoPostingAuthority" VALUES ($1,$2,$3,$4::jsonb)', [org, authority['authorityId'], PreparationRecord.digest(authority), JSON.generate(authority)])
    db.exec_params('INSERT INTO "ToybacoPostingPreparation" VALUES ($1,$2,$3,$4::jsonb,$5,$6::jsonb,$7)', [org, wire['requestId'], receipt['payloadHash'], JSON.generate(wire), receipt['receiptHash'], JSON.generate(receipt), now])
    marker = "TOYBACO_WORKFLOW_V2|ENSURE|#{@reader_generation.tr(':', '|')}|||"
    db.exec_params(%q{INSERT INTO "Post" (id,"integrationId","organizationId","publishDate",state,error,content,image,settings,delay,title,description,"intervalInDays","createdAt","approvedSubmitForOrder","group") VALUES ('reader-root','channel-a',$1,$2,'QUEUE',$3,$4,NULL,$5,0,NULL,'fixture',NULL,$2,'NO','reader-group')}, [org, now, marker, 'fixture body 日本語', '{"fixture":true}'])
    db.exec_params(%q{INSERT INTO "Post" (id,"integrationId","organizationId","publishDate","parentPostId",state,content,delay,"intervalInDays","createdAt","approvedSubmitForOrder","group") VALUES ('reader-child','channel-a',$1,$2,'reader-root','DRAFT','fixture child',3,2,$2,'NO','reader-group')}, [org, now])
    payload = { 'authorityHash' => PreparationRecord.digest(authority), 'rootId' => 'reader-root', 'organizationId' => org,
      'rootGeneration' => @reader_generation, 'integrationId' => 'channel-a', 'publishAt' => (now.to_r * 1000).to_i,
      'postPayloadHash' => reader_expected_payload_hash(now), 'saveRequestId' => READER_UUID, 'savePayloadHash' => 'b' * 64 }
    db.exec_params('INSERT INTO "ToybacoPostingSchedule" VALUES ($1,$2,$3,$4,$5::jsonb,$6)', [org, 'reader-root', @reader_generation, authority['authorityId'], JSON.generate(payload), PreparationRecord.digest(payload)])
    db.exec_params('INSERT INTO "ToybacoPostSaveRequest" VALUES ($1,$2,$3,$4,$5::jsonb)', [org, Toybaco::PostizSync.deterministic_user_id(@owner.id), READER_UUID, 'b' * 64, JSON.generate([{ 'postId' => 'reader-root' }])])
    @reader_change&.call(db)
    @preparation_read_checks.clear
    db
  rescue Exception
    db&.close unless db&.finished?
    raise
  end

  def reader_expected_payload_hash(now)
    common = { 'integrationId' => 'channel-a', 'image' => nil, 'title' => nil, 'publishDate' => now.strftime('%Y-%m-%d %H:%M:%S'),
      'createdAt' => now.strftime('%Y-%m-%d %H:%M:%S'), 'approvedSubmitForOrder' => 'NO' }
    values = [common.merge('id' => 'reader-child', 'parentPostId' => 'reader-root', 'content' => 'fixture child', 'settings' => nil, 'delay' => 3, 'description' => nil, 'intervalInDays' => 2),
      common.merge('id' => 'reader-root', 'parentPostId' => nil, 'content' => 'fixture body 日本語', 'settings' => '{"fixture":true}', 'delay' => 0, 'description' => 'fixture', 'intervalInDays' => nil)]
    PreparationRecord.digest(values)
  end

  def reader_source(context = @reader_context)
    Toybaco::Growth::PostingReleaseSource.new(@account, connector: -> { reader_database }).read(owner_id: @owner.id, authority_context: context)
  end

  def test_authority_reader_known_schedule_is_inventory_only_and_readonly
    reader_fixture
    # Same vector executed against toybacoPostPayloadHash in the generated TS.
    assert_equal 'f48d54b403ee70aab6c7eef2d7f80276a9b639ef83413a492cdae1e1966ddb55', reader_expected_payload_hash(self.class::NOW)
    baseline = @reader_request['inventoryHash']
    result = reader_source
    refute_equal baseline, result['inventory_hash']
    assert_equal @reader_request['identityHash'], result['identity_hash']
    refute JSON.generate(result).include?('fixture body')
    assert @preparation_read_checks.all? { |value| value == ['on', 'repeatable read'] }
    assert @preparation_connections.all?(&:finished?)
    inventory = Toybaco::Growth::RetentionInventory.new(@account, connector: -> { reader_database }, authority_context: @reader_context).read
    assert_equal [{ 'id' => 'reader-root', 'integration_id' => 'channel-a', 'publish_at_us' => (self.class::NOW.to_r * 1_000_000).to_i, 'held' => false }], inventory['posts']
  end

  def test_authority_reader_contextless_and_missing_extension_keep_unknown_queue_closed
    reader_fixture
    assert_raises(Toybaco::Growth::RetentionPlan::Invalid) { reader_source(nil) }
    @reader_change = ->(db) { db.exec('DROP TABLE "ToybacoPostingAuthorityCurrent"') }
    assert_raises(Toybaco::Growth::RetentionPlan::Invalid) { reader_source }
  end

  def test_authority_reader_current_context_and_epoch_changes_reject_old_schedule
    reader_fixture
    %w[principalHash contractHash].each do |key|
      assert_raises(Toybaco::Growth::RetentionPlan::Invalid) { reader_source(@reader_context.merge(key => 'c' * 64)) }
    end
    ["UPDATE \"UserOrganization\" SET role='USER'", 'UPDATE "ToybacoPostingIdentityEpoch" SET generation=2', "UPDATE \"ToybacoPostingAuthorityCurrent\" SET state='stale'"] .each do |sql|
      @reader_change = ->(db) { db.exec(sql) }
      assert_raises(Toybaco::Growth::RetentionPlan::Invalid) { reader_source }
    end
  end

  def test_authority_reader_missing_or_corrupt_durable_links_fail_closed
    reader_fixture
    ['DELETE FROM "ToybacoPostingAuthority"', 'DELETE FROM "ToybacoPostingPreparation"', 'DELETE FROM "ToybacoPostingSchedule"', 'DELETE FROM "ToybacoPostSaveRequest"',
      "UPDATE \"ToybacoPostingAuthority\" SET \"authorityHash\"='bad'", "UPDATE \"ToybacoPostingSchedule\" SET \"scheduleHash\"='bad'", "UPDATE \"ToybacoPostSaveRequest\" SET \"postsJson\"='[]'::jsonb", "UPDATE \"ToybacoPostSaveRequest\" SET \"actorId\"='foreign'"].each do |sql|
      @reader_change = ->(db) { db.exec(sql) }
      assert_raises(Toybaco::Growth::RetentionPlan::Invalid) { reader_source }
    end
  end

  def test_authority_reader_body_comment_and_datetime_drift_fail_closed
    reader_fixture
    ["UPDATE \"Post\" SET content='changed' WHERE id='reader-root'", "UPDATE \"Post\" SET delay=4 WHERE id='reader-child'", "UPDATE \"Post\" SET \"publishDate\"=\"publishDate\"+interval '1 microsecond' WHERE id='reader-root'", "UPDATE \"Post\" SET \"parentPostId\"='missing' WHERE id='reader-child'", "UPDATE \"Post\" SET \"parentPostId\"=NULL WHERE id='reader-child'"].each do |sql|
      @reader_change = ->(db) { db.exec(sql) }
      assert_raises(Toybaco::Growth::RetentionPlan::Invalid) { reader_source }
    end
  end

  def test_authority_reader_unknown_marker_and_other_root_fail_closed
    reader_fixture
    ["UPDATE \"Post\" SET error='arbitrary' WHERE id='reader-root'", "UPDATE \"Post\" SET error=replace(error,'ENSURE','CLAIMED') WHERE id='reader-root'", "UPDATE \"Post\" SET \"integrationId\"='channel-b' WHERE id='reader-root'"] .each do |sql|
      @reader_change = ->(db) { db.exec(sql) }
      assert_raises(Toybaco::Growth::RetentionPlan::Invalid) { reader_source }
    end
  end

  def test_authority_reader_actual_workflow_replace_marker_with_previous_identity
    reader_fixture
    previous = "post_reader-root_g#{(self.class::NOW.to_r * 1000).to_i}_t#{READER_UUID}"
    marker = "TOYBACO_WORKFLOW_V2|REPLACE|#{@reader_generation.tr(':', '|')}|#{previous}|#{READER_UUID}|fixture%20replaced"
    @reader_change = ->(db) { db.exec_params(%q{UPDATE "Post" SET error=$1 WHERE id='reader-root'}, [marker]) }
    assert_equal @reader_request['identityHash'], reader_source['identity_hash']
  end

  def test_authority_reader_short_extra_or_cancel_workflow_marker_is_not_a_known_schedule
    reader_fixture
    prefix = "TOYBACO_WORKFLOW_V2|ENSURE|#{@reader_generation.tr(':', '|')}"
    ["#{prefix}|", "#{prefix}||", "#{prefix}||||", "#{prefix.sub('ENSURE', 'CANCEL')}|||"].each do |marker|
      @reader_change = ->(db) { db.exec_params(%q{UPDATE "Post" SET error=$1 WHERE id='reader-root'}, [marker]) }
      assert_raises(Toybaco::Growth::RetentionPlan::Invalid) { reader_source }
    end
  end

  def test_authority_reader_rescheduled_held_root_requires_exact_current_schedule
    reader_fixture(held_root: true)
    assert_equal @reader_request['identityHash'], reader_source['identity_hash']
    inventory = Toybaco::Growth::RetentionInventory.new(@account, connector: -> { reader_database }, authority_context: @reader_context).read
    assert_equal ['reader-root'], inventory['posts'].pluck('id')
    refute inventory['posts'].first['held']
    assert_raises(Toybaco::Growth::RetentionPlan::Invalid) { reader_source(nil) }
    ['DELETE FROM "ToybacoPostingSchedule"', "UPDATE \"ToybacoPostingAuthorityCurrent\" SET state='stale'", "UPDATE \"Post\" SET content='changed' WHERE id='reader-root'"].each do |sql|
      @reader_change = ->(db) { db.exec(sql) }
      assert_raises(Toybaco::Growth::RetentionPlan::Invalid) { reader_source }
    end
  end

  def test_authority_reader_rejects_individually_valid_but_mismatched_inbox_hold
    reader_fixture(held_root: true)
    attrs = @account.internal_attributes.deep_dup
    hold = attrs.fetch(Toybaco::Growth::InboxRetention::KEY)
    hold['posting_receipt_hash'] = 'f' * 64
    hold['receipt_hash'] = Toybaco::Growth::RetentionSnapshot.fingerprint(hold.slice(*Toybaco::Growth::InboxRetention::FIELDS))
    Toybaco::Growth::InboxRetention.validate!(hold, account_id: @account.id, now: self.class::NOW)
    @account.update_columns(internal_attributes: attrs)
    assert_raises(Toybaco::Growth::RetentionPlan::Invalid) { reader_source }
  end

  def test_authority_reader_unrescheduled_draft_remains_held_without_extension
    reader_fixture(held_root: true)
    @reader_change = lambda do |db|
      db.exec(%q{UPDATE "Post" SET state='DRAFT', error=NULL WHERE id='reader-root'})
      db.exec('DROP TABLE "ToybacoPostingAuthorityCurrent"')
    end
    inventory = Toybaco::Growth::RetentionInventory.new(@account, connector: -> { reader_database }, authority_context: @reader_context).read
    assert_equal ['reader-root'], inventory['posts'].pluck('id')
    assert inventory['posts'].first['held']
  end

  def test_authority_reader_publish_ready_marker_matches_same_immutable_schedule
    reader_fixture
    @reader_change = ->(db) { db.exec_params(%q{UPDATE "Post" SET error=$1 WHERE id='reader-root'}, ["TOYBACO_PUBLISH_V2|#{@reader_generation.tr(':','|')}|READY"]) }
    assert_equal @reader_request['identityHash'], reader_source['identity_hash']
  end

  def test_authority_reader_future_or_changed_preparation_receipt_fails
    reader_fixture
    ["UPDATE \"ToybacoPostingPreparation\" SET \"createdAt\"=\"createdAt\"+interval '1 second'", "UPDATE \"ToybacoPostingPreparation\" SET receipt=jsonb_set(receipt,'{execute}','true')", "UPDATE \"ToybacoPostingPreparation\" SET request=jsonb_set(request,'{keepIntegrationIds}','[\"channel-b\"]')"].each do |sql|
      @reader_change = ->(db) { db.exec(sql) }
      assert_raises(Toybaco::Growth::RetentionPlan::Invalid) { reader_source }
    end
  end

  def test_authority_reader_old_schema_without_unknown_queue_needs_no_extension
    reader_fixture
    connector = lambda do
      db = preparation_database
      if db.exec(%q{SELECT to_regclass('"ToybacoPostingAuthorityCurrent"')}).getvalue(0, 0)
        db.exec('DROP TABLE "ToybacoPostingAuthorityCurrent"')
      end
      db
    end
    value = Toybaco::Growth::PostingReleaseSource.new(@account, connector: connector).read(owner_id: @owner.id, authority_context: @reader_context)
    assert_equal @reader_request['inventoryHash'], value['inventory_hash']
    assert @preparation_connections.all?(&:finished?)
  end

  def test_authority_reader_copies_context_and_rejects_invalid_context_before_connecting
    reader_fixture
    context = @reader_context.deep_dup
    reader = Toybaco::Growth::RetentionInventory.new(@account, connector: -> { reader_database }, authority_context: context)
    context['principalHash'].replace('c' * 64)
    assert_equal ['reader-root'], reader.read['posts'].pluck('id')
    [@reader_context.merge('actorId' => @owner.id + 1), @reader_context.merge('principalHash' => 'bad'),
      @reader_context.merge('execute' => true)].each do |invalid|
      assert_raises(Toybaco::Growth::RetentionPlan::Invalid) do
        Toybaco::Growth::RetentionInventory.new(@account, connector: -> { flunk 'invalid input opened a connection' }, authority_context: invalid)
      end
    end
  end
end
