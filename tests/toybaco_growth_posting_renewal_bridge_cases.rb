# frozen_string_literal: true

require Rails.root.join('lib/toybaco/growth/posting_renewal_bridge')
require Rails.root.join('lib/toybaco/growth/posting_renewal_execution_proof')

# Actual Rails records/readers and isolated PG; Stripe and remote bridge answers
# are fixtures. No model here claims a real provider call or deployed release.
module ToybacoPostingRenewalBridgeCases
  N3 = Toybaco::Growth
  PreparationRecord = N3::PostingPreparationRecord
  READER_UUID = '11111111-1111-4111-8111-111111111111'
  def n3b_environment
    authority_environment.merge('TOYBACO_POSTING_RENEWAL_ENABLED'=>'true','TOYBACO_POSTING_EXECUTION_ENABLED'=>'true')
  end

  def n3b_current(kind:'renewal_grace')
    input,operation=n3i_fixture
    if kind=='renewal_paid'
      @n3_provider=n3_subscription(@n3_boundary,@n3_boundary+30.days.to_i,'in_failed',paid:true,paid_at:@n3_boundary+60)
      n3_mutate('toybaco_subscription_status'=>'active')
      N3::PaidPeriod.new(@account,now:n3_now).observe!(@n3_provider)
    end
    result=n3i_prepare(input,operation,kind:kind)
    adapter=n3i_transport { |payload,response| n3b_history_response(payload,response) if @n3b_history }
    n3i_service(transport:adapter).deliver!(request_id:result['request_id'])
    Toybaco::GrowthPostingRenewal.find_by!(request_id:result['request_id'])
  end

  def n3b_execution(row, authority_id:row.target_authority_id)
    authority=Toybaco::GrowthPostingAuthority.find_by!(account_id:@account.id,authority_id:authority_id)
    {'authorityId'=>authority_id,'authorityHash'=>authority.postiz_receipt['authorityHash'],
     'railsAuthorityHash'=>authority.receipt['receipt_hash'],'accountId'=>@account.id,
     'organizationId'=>row.receipt.dig('posting','organization_id'),'ownerId'=>@owner.id,'actorId'=>@owner.id,
     'rootId'=>'reader-root','stepPostId'=>'reader-root','step'=>'MAIN','rootGeneration'=>"#{(self.class::NOW.to_r*1000).to_i}:#{READER_UUID}",
     'markerHash'=>'b'*64,'saveRequestId'=>READER_UUID,'scheduleHash'=>'c'*64,'reservationHash'=>'d'*64,
     'sequence'=>0,'previousPendingHash'=>nil,'pendingDataHash'=>nil}
  end

  def n3b_service(input,environment:n3b_environment)
    Toybaco::Growth::PostingExecutionV3.new(input,client:n3i_client,environment:environment,clock:-> {n3_now})
  end

  def test_n3b_grace_current_uses_dedicated_real_admission_and_one_start
    row=n3b_current
    input=n3b_execution(row)
    result=n3b_service(input).start!
    assert_equal ['started',false],[result['state'],result['execute']]
    assert_equal result,n3b_service(input).start!
    assert_equal 1,Toybaco::GrowthPostingExecution.where(account_id:@account.id).count
    assert_raises(PreparationRecord::Invalid){n3b_service(input.merge('authorityId'=>row.source_authority_id)).start!}
    assert_equal 'uncertain',n3b_service(input).result!(outcome:'uncertain',evidence_hash:'e'*64)['state']
    assert_raises(N3::PostingExecutionContext::Busy){@account.reload.update!(status:'suspended')}
  end

  def test_n3b_paid_recovery_is_current_but_new_activation_stays_closed
    row=n3b_current(kind:'renewal_paid')
    assert @account.reload.internal_attributes.key?(N3::RenewalGrace::FAILURE_KEY)
    input=n3b_execution(row)
    assert_equal 'started',n3b_service(input).start!['state']
    n3b_service(input).result!(outcome:'rejected',evidence_hash:'e'*64)
    old=n3b_execution(row,authority_id:row.source_authority_id).merge('rootId'=>'old-root','stepPostId'=>'old-root')
    assert_raises(PreparationRecord::Invalid){n3b_service(old).start!}
    assert_equal row.receipt['evidence']['coverage'],N3::PostingAuthorityRecord.effective_preparation!(Toybaco::GrowthPostingAuthority.find_by!(authority_id:row.target_authority_id),now:n3_now).dig('binding','coverage')
  end

  def test_n3b_expiry_manual_suspend_flag_and_new_failure_do_not_grant_start
    row=n3b_current
    input=n3b_execution(row)
    assert_raises(PreparationRecord::Invalid){n3b_service(input,environment:n3b_environment.merge('TOYBACO_POSTING_RENEWAL_ENABLED'=>'false')).start!}
    attrs=@account.reload.internal_attributes.deep_dup
    @account.update_columns(internal_attributes:attrs.merge('toybaco_billing_suspended'=>true))
    assert_raises(PreparationRecord::Invalid){n3b_service(input).start!}
    @account.update_columns(internal_attributes:attrs)
    failure=attrs.fetch(N3::RenewalGrace::FAILURE_KEY).merge('invoice_id'=>'in_foreign')
    @account.update_columns(internal_attributes:attrs.merge(N3::RenewalGrace::FAILURE_KEY=>failure))
    assert_raises(PreparationRecord::Invalid){n3b_service(input).start!}
    @account.update_columns(internal_attributes:attrs)
    n3_time(row.receipt.dig('evidence','expires_at'))
    assert_raises(PreparationRecord::Invalid){n3b_service(input).start!}
    assert_equal 0,Toybaco::GrowthPostingExecution.where(account_id:@account.id).count
  end

  def test_n3b_paid_upgrade_to_next_ordinary_paid_period_validates_old_upgrade_invoice
    n3b_current(kind:'renewal_paid')
    paid_renewal_target
    paid_renewal_service.call(operation_id:'7'*64)
    current=Toybaco::GrowthPostingAuthority.find_by!(authority_id:Toybaco::GrowthPostingAuthorityCurrent.find_by!(account_id:@account.id).authority_id)
    source=N3::PostingAuthorityRecord.effective_preparation!(current,now:n3_now)
    @n3_contract=source['binding']['contract']
    previous=source.dig('binding','coverage')
    @n3_previous_invoice=@paid_renewal_provider.fetch('latest_invoice').deep_dup
    @n3_boundary=previous['term_end']
    n3_time(@n3_boundary+3600)
    @n3_provider=n3_subscription(@n3_boundary,@n3_boundary+30.days.to_i,'in_nextcycle',paid:true,paid_at:@n3_boundary+60)
    N3::PaidPeriod.new(@account,now:n3_now).observe!(@n3_provider)
    result=n3i_prepare({'authorityId'=>current.authority_id},nil,kind:'renewal_paid',request:'8'*64)
    row=Toybaco::GrowthPostingRenewal.find_by!(request_id:result['request_id'])
    assert_equal 'paid_upgrade',row.receipt['source_kind']
    assert_equal current.receipt['revision'],row.receipt.dig('previous_upgrade','operation_id')
    assert_equal previous,row.receipt.dig('evidence','previous_coverage')
    assert_equal 'ready',n3i_service(transport:n3i_transport).deliver!(request_id:result['request_id'])['state']
    @n3_previous_invoice['amount_paid']=0
    assert_raises(PreparationRecord::Invalid){n3b_service(n3b_execution(row)).start!}
  end

  def n3b_pending_database
    db=paid_renewal_reader_database
    org=@reader_request.fetch('organizationId')
    authority=JSON.parse(db.exec_params('SELECT payload FROM "ToybacoPostingAuthority" WHERE "authorityId"=$1',['3'*64]).getvalue(0,0))
    pointer={'organizationId'=>org,'authorityId'=>authority['authorityId'],'generation'=>'2','epoch'=>READER_UUID,'state'=>'pending'}
    db.exec_params('UPDATE "ToybacoPostingAuthorityCurrent" SET "authorityId"=$1,generation=2,epoch=$2,state=$3',[authority['authorityId'],READER_UUID,'pending'])
    row=db.exec('SELECT * FROM "ToybacoPostingRenewal"').first
    request=JSON.parse(row['request']);receipt=JSON.parse(row['receipt'])
    receipt['targetPointerHash']=PreparationRecord.digest(pointer.except('state'))
    fingerprint=PreparationRecord.digest(receipt)
    db.exec_params('UPDATE "ToybacoPostingRenewal" SET state=$1,receipt=$2::jsonb,"receiptHash"=$3',['applied',JSON.generate(receipt),fingerprint])
    edge=db.exec_params('SELECT payload FROM "ToybacoPostingScheduleContinuation" WHERE "targetAuthorityId"=$1',[authority['authorityId']]).first
    payload=JSON.parse(edge['payload']).merge('handoffReceiptHash'=>fingerprint)
    db.exec_params('UPDATE "ToybacoPostingScheduleContinuation" SET payload=$1::jsonb,"continuationHash"=$2 WHERE "targetAuthorityId"=$3',[JSON.generate(payload),PreparationRecord.digest(payload),authority['authorityId']])
    @n3b_scope=request.slice('operationId','sourceAuthorityId','sourceAuthorityHash','targetAuthorityId','targetAuthorityHash','handoffReceiptHash').merge('targetPointerHash'=>receipt['targetPointerHash'])
    @n3b_fault&.call(db)
    @preparation_read_checks.clear
    db
  end

  def test_n3b_pending_recovery_classification_is_explicit_and_never_general_readiness
    reader_fixture
    # Build the exact server-side scope independently of the reader invocation.
    db=n3b_pending_database;db.close
    scope=@n3b_scope.deep_dup
    generic=-> {N3::PostingReleaseSource.new(@account,connector:-> {n3b_pending_database}).read(owner_id:@owner.id,authority_context:@reader_context)}
    assert_raises(N3::RetentionPlan::Invalid){generic.call}
    reader=->(value) {N3::PostingReleaseSource.new(@account,connector:-> {n3b_pending_database},renewal_recovery:value).read(owner_id:@owner.id,authority_context:@reader_context)}
    assert_equal @reader_request['identityHash'],reader.call(scope)['identity_hash']
    %w[operationId sourceAuthorityHash targetAuthorityId handoffReceiptHash targetPointerHash].each do |key|
      assert_raises(N3::RetentionPlan::Invalid){reader.call(scope.merge(key=>'f'*64))}
    end
    @n3b_fault=->(db){db.exec('UPDATE "ToybacoPostingIdentityEpoch" SET generation=2')}
    assert_raises(N3::RetentionPlan::Invalid){reader.call(scope)}
    assert @preparation_read_checks.all?{|x| x==['on','repeatable read']}
  end

  def n3b_history_response(payload,response)
    if payload['phase']=='confirm'
      receipt=@n3b_history_snapshot.fetch(:receipt)
      response.merge!('receiptHash'=>PreparationRecord.digest(receipt),'rootManifestHash'=>receipt['rootManifestHash'])
      return
    end
    renewal=Toybaco::GrowthPostingRenewal.find_by!(request_id:payload['operationId'])
    source=Toybaco::GrowthPostingAuthority.find_by!(authority_id:renewal.source_authority_id)
    prepared=N3::PostingAuthorityRecord.preparation!(source,now:n3_now)
    ack=N3::PostingRenewalAuthority.ack!(source,prepared,n3b_environment,n3_now)
    request=N3::PostingPreparationExport.request(prepared,@account.id,now:n3_now)
    original=N3::PostingAuthorityRecord.wire(source,ack,now:n3_now)
    generation="#{(self.class::NOW.to_r*1000).to_i}:#{READER_UUID}"
    schedule={'authorityHash'=>PreparationRecord.digest(original),'rootId'=>'reader-root','organizationId'=>payload['organizationId'],
      'rootGeneration'=>generation,'integrationId'=>'channel-a','publishAt'=>(self.class::NOW.to_r*1000).to_i,
      'postPayloadHash'=>'2'*64,'saveRequestId'=>READER_UUID,'savePayloadHash'=>'3'*64}
    root={'rootId'=>'reader-root','rootGeneration'=>generation,'scheduleHash'=>PreparationRecord.digest(schedule),
      'saveRequestId'=>READER_UUID,'postPayloadHash'=>schedule['postPayloadHash'],'markerHash'=>'b'*64,
      'state'=>'PUBLISHED','descendantsHash'=>'4'*64,'originalAuthorityId'=>source.authority_id,'originalAuthorityHash'=>PreparationRecord.digest(original)}
    receipt={'version'=>1,'organizationId'=>payload['organizationId'],'operationId'=>payload['operationId'],
      'requestHash'=>PreparationRecord.digest(payload.except('phase')),'roots'=>[root],
      'rootManifestHash'=>PreparationRecord.digest([root]),'targetPointerHash'=>response['targetPointerHash']}
    response.merge!('receiptHash'=>PreparationRecord.digest(receipt),'rootManifestHash'=>receipt['rootManifestHash'])
    @n3b_history_snapshot={request:request,prepared:ack.dig('response','preparation'),source:original,target:payload['targetAuthority'],
      schedule:schedule,root:root,renewal:payload,receipt:receipt}
  end

  def n3b_execution_database
    data=@n3b_history_snapshot
    config=Account.connection_pool.db_config.configuration_hash
    db=PG.connect(host:config[:host],port:config[:port],dbname:config[:database],user:config[:username],password:config[:password])
    @preparation_connections << db
    db.exec('CREATE TEMP TABLE "ToybacoPostingAuthority" ("organizationId" text,"authorityId" text,"authorityHash" text,payload jsonb)')
    db.exec('CREATE TEMP TABLE "ToybacoPostingPreparation" ("organizationId" text,"requestId" text,"payloadHash" text,request jsonb,"receiptHash" text,receipt jsonb,"createdAt" timestamp)')
    db.exec('CREATE TEMP TABLE "ToybacoPostingSchedule" ("organizationId" text,"rootId" text,"rootGeneration" text,"authorityId" text,payload jsonb,"scheduleHash" text)')
    db.exec('CREATE TEMP TABLE "ToybacoPostingRenewal" ("organizationId" text,"operationId" text,"requestHash" text,request jsonb,"receiptHash" text,receipt jsonb,state text)')
    db.exec('CREATE TEMP TABLE "ToybacoPostingScheduleContinuation" ("organizationId" text,"rootId" text,"rootGeneration" text,"targetAuthorityId" text,payload jsonb,"continuationHash" text)')
    org=data[:source]['organizationId'];request=data[:request];prep=data[:prepared];renewal=data[:renewal];receipt=data[:receipt];schedule=data[:schedule];root=data[:root]
    [data[:source],data[:target]].each { |value| db.exec_params('INSERT INTO "ToybacoPostingAuthority" VALUES ($1,$2,$3,$4::jsonb)',[org,value['authorityId'],PreparationRecord.digest(value),JSON.generate(value)]) }
    db.exec_params('INSERT INTO "ToybacoPostingPreparation" VALUES ($1,$2,$3,$4::jsonb,$5,$6::jsonb,$7)',[org,request['requestId'],prep['payloadHash'],JSON.generate(request),prep['receiptHash'],JSON.generate(prep),Time.at(Rational(prep['preparedAt'],1000)).utc])
    db.exec_params('INSERT INTO "ToybacoPostingSchedule" VALUES ($1,$2,$3,$4,$5::jsonb,$6)',[org,root['rootId'],root['rootGeneration'],data[:source]['authorityId'],JSON.generate(schedule),root['scheduleHash']])
    db.exec_params('INSERT INTO "ToybacoPostingRenewal" VALUES ($1,$2,$3,$4::jsonb,$5,$6::jsonb,$7)',[org,renewal['operationId'],receipt['requestHash'],JSON.generate(renewal),PreparationRecord.digest(receipt),JSON.generate(receipt),'ready'])
    edge=root.merge('kind'=>renewal['kind'],'organizationId'=>org,'operationId'=>renewal['operationId'],'handoffReceiptHash'=>PreparationRecord.digest(receipt),
      'sourceAuthorityId'=>data[:source]['authorityId'],'sourceAuthorityHash'=>PreparationRecord.digest(data[:source]),'targetAuthorityId'=>data[:target]['authorityId'],'targetAuthorityHash'=>PreparationRecord.digest(data[:target]))
    db.exec_params('INSERT INTO "ToybacoPostingScheduleContinuation" VALUES ($1,$2,$3,$4,$5::jsonb,$6)',[org,root['rootId'],root['rootGeneration'],data[:target]['authorityId'],JSON.generate(edge),PreparationRecord.digest(edge)])
    @n3b_proof_fault&.call(db)
    db
  end

  def test_n3b_original_published_main_to_renewal_then_paid_comment_preserves_identity
    @n3b_history=true
    renewal=n3b_current(kind:'renewal_paid')
    old=n3b_execution(renewal,authority_id:renewal.source_authority_id).merge('scheduleHash'=>@n3b_history_snapshot[:root]['scheduleHash'])
    protocol=N3::PostingExecutionProtocol
    operation=protocol.operation_id(old)
    # Provider publication is a fixture; the stored request, terminal record,
    # immutable authority chain, PostgreSQL schedule proof and V3 admission are real.
    main=Toybaco::GrowthPostingExecution.create!(account_id:@account.id,operation_id:operation,identity_hash:operation,
      request:old.merge('version'=>3),request_hash:PreparationRecord.digest(old),state:'completed',outcome:'published',evidence_hash:'f'*64,
      started_at:self.class::NOW,terminal_at:self.class::NOW+1,created_at:self.class::NOW,updated_at:self.class::NOW+1)
    paid_renewal_target
    paid_renewal_service.call(operation_id:'7'*64)
    current=Toybaco::GrowthPostingAuthority.find_by!(authority_id:Toybaco::GrowthPostingAuthorityCurrent.find_by!(account_id:@account.id).authority_id)
    @n3_provider=@paid_renewal_provider.deep_dup
    input=old.merge('authorityId'=>current.authority_id,'authorityHash'=>current.postiz_receipt['authorityHash'],'railsAuthorityHash'=>current.receipt['receipt_hash'],
      'step'=>'COMMENT','stepPostId'=>'reader-child','markerHash'=>'5'*64,'reservationHash'=>'6'*64)
    constructor=N3::PostingRenewalExecutionProof.method(:new)
    factory=->(execution,previous,now:) {constructor.call(execution,previous,now:now,connector:-> {n3b_execution_database})}
    N3::PostingRenewalExecutionProof.stub(:new,factory) do
      assert_equal 'started',n3b_service(input).start!['state']
      assert_equal 'started',n3b_service(input).start!['state']
      assert_equal 2,Toybaco::GrowthPostingExecution.where(account_id:@account.id).count
      n3b_service(input).result!(outcome:'published',evidence_hash:'a'*64)
      assert_raises(PreparationRecord::Invalid){n3b_service(input.merge('step'=>'MAIN','stepPostId'=>'reader-root')).start!}
      @n3b_proof_fault=->(db){db.exec(%q{UPDATE "ToybacoPostingScheduleContinuation" SET "continuationHash"=repeat('0',64)})}
      assert_raises(N3::RetentionPlan::Invalid){n3b_service(input.merge('stepPostId'=>'another-child')).start!}
      @n3b_proof_fault=nil
      main.update_columns(outcome:'not_sent')
      assert_raises(PreparationRecord::Invalid){n3b_service(input.merge('stepPostId'=>'another-child')).start!}
      main.update_columns(state:'uncertain',outcome:nil,evidence_hash:nil,terminal_at:nil,uncertain_evidence_hash:'f'*64)
      assert_raises(PreparationRecord::Invalid){n3b_service(input.merge('stepPostId'=>'another-child')).start!}
    end
  end

  def test_n3b_confirm_cannot_replace_prepared_root_manifest_or_receipt
    input,operation=n3i_fixture
    result=n3i_prepare(input,operation)
    adapter=n3i_transport do |payload,response|
      response['rootManifestHash']='f'*64 if payload['phase']=='confirm'
    end
    assert_raises(PreparationRecord::Invalid){n3i_service(transport:adapter).deliver!(request_id:result['request_id'])}
    row=Toybaco::GrowthPostingRenewal.find_by!(request_id:result['request_id'])
    assert_equal 'applied',row.state
    assert_nil row.confirm_receipt
    assert_equal 'pending',Toybaco::GrowthPostingAuthority.find_by!(authority_id:row.target_authority_id).postiz_receipt['state']
    assert_equal 'ready',n3i_service(transport:n3i_transport).deliver!(request_id:row.request_id)['state']
  end

  def test_n3b_http_protocol_direction_purpose_age_and_exact_reply
    row=n3b_current
    input=n3i_service.send(:exchange_payload,row,'confirm')
    protocol=N3::PostingRenewalHttpProtocol
    config=protocol.configuration(n3b_environment)
    envelope=protocol.request(input,config:config)
    response=n3i_transport.call(input)
    value={'version'=>1,'request_sha256'=>Digest::SHA256.hexdigest(JSON.generate(envelope)),'renewal'=>response}
    raw=JSON.generate(value)
    header=protocol.signature(raw,key:config[:key],now:n3_now,direction:'RESPONSE')
    assert_equal value,protocol.response!(raw,header:header,key:config[:key],now:n3_now,request:envelope)
    assert_raises(PreparationRecord::Invalid){protocol.response!(raw,header:protocol.signature(raw,key:config[:key],now:n3_now,direction:'REQUEST'),key:config[:key],now:n3_now,request:envelope)}
    assert_raises(PreparationRecord::Invalid){protocol.response!(raw,header:header,key:config[:key],now:n3_now+61,request:envelope)}
    assert_raises(PreparationRecord::Invalid){protocol.response!(raw+' ',header:protocol.signature(raw+' ',key:config[:key],now:n3_now,direction:'RESPONSE'),key:config[:key],now:n3_now,request:envelope)}
    assert_raises(PreparationRecord::Invalid){protocol.response!(raw,header:header,key:config[:key],now:n3_now,request:envelope.merge('mode'=>'live'))}
    assert_equal 'toybaco-posting-renewal-v1',N3::PostingRenewalBridge.new(environment:n3b_environment).verified_protocol
  end
end
