# frozen_string_literal: true

require Rails.root.join('lib/toybaco/growth/posting_authority')
require Rails.root.join('lib/toybaco/growth/posting_execution_v3')
require Rails.root.join('lib/toybaco/growth/posting_owner_inventory')

module ToybacoPostingAuthorityRuntimeCases
 PreparationRecord=Toybaco::Growth::PostingPreparationRecord
 PreparationProtocol=Toybaco::Growth::PostingPreparationProtocol
 NOW=Time.utc(2026,10,11,12)
 def preparation_database
  db=super
  db.exec('CREATE TEMP TABLE "ToybacoPostingAuthorityCurrent" ("organizationId" text,"authorityId" text,generation bigint,epoch uuid,state text)')
  if @authority_pointer
   db.exec_params('INSERT INTO "ToybacoPostingAuthorityCurrent" VALUES ($1,$2,1,$3,$4)',[@authority_pointer['organizationId'],@authority_pointer['authorityId'],'11111111-1111-4111-8111-111111111111',@authority_pointer['state']])
  end
  db
 end
 def teardown
  Toybaco::GrowthPostingAuthorityCurrent.where(account_id: @account.id).delete_all
  Toybaco::GrowthPostingAuthority.where(account_id: @account.id).delete_all
  Toybaco::GrowthPostingExecution.where(account_id: @account.id).delete_all
  super
 end
 def authority_environment
  bridge_environment.merge('TOYBACO_POSTING_RELEASE_ENABLED'=>'true','TOYBACO_POSTING_AUTHORITY_ENABLED'=>'true','TOYBACO_POSTING_EXECUTION_ENABLED'=>'true')
 end
 def authority_response(payload)
  raise 'HTTP inside transaction' if Account.connection.transaction_open?
  wire=payload.fetch('authority')
  state=payload['operation']=='activate' ? 'pending' : 'ready'
  @authority_pointer={'organizationId'=>wire['organizationId'],'authorityId'=>wire['authorityId'],'generation'=>'1','epoch'=>'11111111-1111-4111-8111-111111111111','state'=>state}
  {'version'=>1,'request_sha256'=>Digest::SHA256.hexdigest(JSON.generate(payload)), 'authority'=>{'authorityId'=>wire['authorityId'],'organizationId'=>wire['organizationId'],'authorityHash'=>PreparationRecord.digest(wire),'state'=>state,'current'=>true,'execute'=>false,'pointerHash'=>PreparationRecord.digest(@authority_pointer.except('state'))}}
 end
 def authority_service(transport=nil)
  svc=Toybaco::Growth::PostingAuthority.new(@account,@owner,client:@release_provider,environment:authority_environment,clock:-> { NOW },transport:transport||method(:authority_response)) { preparation_database }
  svc
 end
 def authority_fixture
  prepare_posting_preparation
  prepared=prepare_posting['receipt']
  preparation_delivery(->(p) { preparation_response(p) }).call(request_id:prepared['request_id'])
  prepared
 end
 def activate_fixture(transport=nil)
  prepared=authority_fixture
  svc=authority_service(transport)
  revision=svc.read(preparation_request_id:prepared['request_id'])['revision']
  request={preparation_request_id:prepared['request_id'],authority_id:'a'*64,revision:revision}
  [svc,request,svc.activate!(**request)]
 end
 def test_authority_activation_and_replay_have_no_execution_or_schedule_side_effect
  svc,request,result=activate_fixture
  assert_equal({'authority_id'=>'a'*64,'state'=>'active','current'=>true,'execute'=>false},result)
  original=Toybaco::GrowthPostingAuthority.first.receipt.deep_dup
  assert_equal(result,svc.activate!(**request))
  assert_equal(1,Toybaco::GrowthPostingAuthority.count)
  assert_equal(original,Toybaco::GrowthPostingAuthority.first.receipt)
  assert_equal(1,Toybaco::GrowthPostingAuthorityCurrent.first.generation)
  assert_equal(0,Toybaco::GrowthPostingExecution.count)
 end
 def test_owner_inventory_passes_existing_principal_without_creating_admission_or_refreshing_authority
  activate_fixture
  before=Toybaco::GrowthPostingAuthority.first.attributes
  count=Toybaco::GrowthPostingPrincipal.count
  captured=[]
  inventory=Object.new
  inventory.define_singleton_method(:read) { {'posts'=>[]} }
  reader=Toybaco::Growth::PostingOwnerInventory.new(@account,@owner,clock:-> { NOW })
  Toybaco::Growth::RetentionInventory.stub(:new,->(_account,**options) {captured<<options[:authority_context];inventory}) do
   assert_equal({'posts'=>[]},reader.read)
  end
  principal=PreparationRecord.find(@account.id,before['preparation_request_id'],now:NOW)['principal']
  assert_equal(PreparationRecord.digest(principal),captured.first['principalHash'])
  assert_equal(@owner.id,captured.first['ownerId'])
  assert_equal(count,Toybaco::GrowthPostingPrincipal.count)
  assert_equal(before,Toybaco::GrowthPostingAuthority.first.attributes)
  assert_equal(0,Toybaco::GrowthPostingExecution.count)
 end
 def test_owner_inventory_rejects_membership_epoch_change_during_postiz_read
  activate_fixture
  inventory=Object.new
  account=@account;owner=@owner
  inventory.define_singleton_method(:read) do
   account.with_lock { Toybaco::Growth::PostingPrincipal.rotate!(account.id,user_ids:[owner.id],now:NOW) }
   {'posts'=>[]}
  end
  reader=Toybaco::Growth::PostingOwnerInventory.new(@account,@owner,clock:-> { NOW })
  Toybaco::Growth::RetentionInventory.stub(:new,inventory) do
   assert_raises(PreparationRecord::Invalid) {reader.read}
  end
  assert_nil(Toybaco::GrowthPostingAuthorityCurrent.first.authority_id)
 end
 def test_owner_inventory_without_authority_creates_no_principal_and_supports_locked_selection
  prepare_posting_preparation
  before=Toybaco::GrowthPostingPrincipal.count
  inventory=Object.new;inventory.define_singleton_method(:read) { {'posts'=>[]} }
  captured=[]
  reader=Toybaco::Growth::PostingOwnerInventory.new(@account,@owner,clock:-> { NOW })
  Toybaco::Growth::RetentionInventory.stub(:new,->(_account,**options) {captured<<options[:authority_context];inventory}) do
   @account.with_lock { assert_equal({'posts'=>[]},reader.read) }
  end
  assert_equal([nil],captured)
  assert_equal(before,Toybaco::GrowthPostingPrincipal.count)
  assert_equal(0,Toybaco::GrowthPostingAuthorityCurrent.count)
 end
 def test_authority_postiz_commit_response_loss_recovers_same_immutable_request
  prepared=authority_fixture; calls=[]; failed=false
  svc=authority_service(->(p) { calls<<p.deep_dup; result=authority_response(p); unless failed; failed=true; raise Timeout::Error; end; result })
  request={preparation_request_id:prepared['request_id'],authority_id:'b'*64,revision:svc.read(preparation_request_id:prepared['request_id'])['revision']}
  assert_raises(Timeout::Error) { svc.activate!(**request) }
  assert_equal('pending',Toybaco::GrowthPostingAuthority.first.state)
  assert_equal(0,Toybaco::GrowthPostingAuthorityCurrent.count)
  assert_equal('active',svc.activate!(**request)['state'])
  assert_equal(calls[0],calls[1])
 end
 def test_authority_rails_active_then_confirm_loss_recovers_without_rotating_pointer
  prepared=authority_fixture;failed=false
  svc=authority_service(->(p) { result=authority_response(p); if p['operation']=='confirm'&&!failed;failed=true;raise Timeout::Error;end;result })
  request={preparation_request_id:prepared['request_id'],authority_id:'b'*64,revision:svc.read(preparation_request_id:prepared['request_id'])['revision']}
  assert_raises(Timeout::Error) { svc.activate!(**request) }
  before=Toybaco::GrowthPostingAuthorityCurrent.first.attributes
  assert_equal('active',svc.activate!(**request)['state'])
  assert_equal(before,Toybaco::GrowthPostingAuthorityCurrent.first.attributes)
 end
 def test_authority_owner_epoch_rotation_clears_pointer_and_old_replay_is_history
  svc,request=activate_fixture
  @account.with_lock { Toybaco::Growth::PostingPrincipal.rotate!(@account.id,user_ids:[@owner.id],now:NOW) }
  assert_nil(Toybaco::GrowthPostingAuthorityCurrent.first.authority_id)
  assert_equal('stale',svc.activate!(**request)['state'])
  assert_nil(Toybaco::GrowthPostingAuthorityCurrent.first.authority_id)
 end
 def test_authority_contract_change_during_http_cannot_commit_local_activation
  prepared=authority_fixture
  svc=authority_service(->(p) { result=authority_response(p);@account.with_lock { Toybaco::Growth::PostingPrincipal.rotate!(@account.id,user_ids:[@owner.id],now:NOW) };result })
  req={preparation_request_id:prepared['request_id'],authority_id:'b'*64,revision:svc.read(preparation_request_id:prepared['request_id'])['revision']}
  assert_raises(Toybaco::Growth::PostingExecutionContext::Invalid) {svc.activate!(**req)}
  assert_equal('pending',Toybaco::GrowthPostingAuthority.first.state)
  assert_equal(0,Toybaco::GrowthPostingAuthorityCurrent.count)
 end
 def execution_fixture
  activate_fixture
  row=Toybaco::GrowthPostingAuthority.first
  config=PreparationProtocol.configuration(authority_environment)
  prepared=PreparationRecord.find(@account.id,row.preparation_request_id,now:NOW)
  ack=Toybaco::Growth::PostingPreparationAck.find(prepared,PreparationProtocol.request(prepared,@account.id,config:config,now:NOW),now:NOW)
  wire=Toybaco::Growth::PostingAuthorityRecord.wire(row,ack,now:NOW)
  {'authorityId'=>row.authority_id,'authorityHash'=>PreparationRecord.digest(wire),'railsAuthorityHash'=>row.receipt['receipt_hash'],'accountId'=>@account.id,'organizationId'=>wire['organizationId'],'ownerId'=>@owner.id,'actorId'=>@owner.id,'rootId'=>'root-fixture','stepPostId'=>'root-fixture','step'=>'MAIN','rootGeneration'=>'1791716400000:11111111-1111-4111-8111-111111111111','markerHash'=>'b'*64,'saveRequestId'=>'11111111-1111-4111-8111-111111111111','scheduleHash'=>'c'*64,'reservationHash'=>'d'*64,'sequence'=>0,'previousPendingHash'=>nil,'pendingDataHash'=>nil}
 end
 def execution_service(input,environment:authority_environment)
  Toybaco::Growth::PostingExecutionV3.new(input,client:@release_provider,environment:environment,clock:-> { NOW })
 end
 def start_execution(input)
  execution_service(input).start!
 end
 def test_execution_one_start_duplicate_and_never_execute_true
  input=execution_fixture
  one=start_execution(input);two=start_execution(input)
  assert_equal(one,two);assert_equal('started',one['state']);assert_equal(false,one['execute'])
  assert_equal(1,Toybaco::GrowthPostingExecution.count)
  assert_raises(PreparationRecord::Invalid) { start_execution(input.merge('reservationHash'=>'e'*64)) }
 end
 def test_execution_pending_main_finalize_and_late_pending_receipt
  input=execution_fixture;start_execution(input)
  main=execution_service(input)
  assert_equal('pending',main.result!(outcome:'pending',evidence_hash:'a'*64)['state'])
  assert_raises(Toybaco::Growth::PostingExecutionContext::Busy) {@account.update!(name:'should-still-be-allowed-contract-identical',internal_attributes:@account.internal_attributes.merge('postiz'=>{'enabled'=>false}))}
  final=input.merge('step'=>'FINALIZE','reservationHash'=>'e'*64,'sequence'=>1,'previousPendingHash'=>'a'*64,'pendingDataHash'=>'b'*64)
  start_execution(final)
  assert_equal('completed',execution_service(final).result!(outcome:'published',evidence_hash:'f'*64)['state'])
  assert_equal('completed',main.status['state'])
  assert_equal('published',main.status['outcome'])
  assert_equal('completed',main.result!(outcome:'pending',evidence_hash:'a'*64)['state'])
 end
 def test_execution_direct_status_completion_and_flag_off_recovery
  input=execution_fixture;start_execution(input);main=execution_service(input)
  main.result!(outcome:'pending',evidence_hash:'a'*64)
  stopped=execution_service(input,environment:{})
  assert_equal('completed',stopped.result!(outcome:'published',evidence_hash:'b'*64)['state'])
  assert_equal('published',stopped.status['outcome'])
  assert_raises(PreparationRecord::Invalid) {stopped.start!}
 end
 def test_execution_not_sent_cannot_rearm_and_pending_cannot_be_not_sent
  input=execution_fixture;start_execution(input);main=execution_service(input)
  assert_equal('completed',main.result!(outcome:'not_sent',evidence_hash:'a'*64)['state'])
  assert_equal('not_sent',start_execution(input)['outcome'])
  assert_equal(1,Toybaco::GrowthPostingExecution.count)
 end
 def test_execution_unadmitted_comment_and_bad_scope_fail
  input=execution_fixture
  assert_equal('absent',execution_service(input).status['state'])
  assert_raises(PreparationRecord::Invalid) {start_execution(input.merge('step'=>'COMMENT','stepPostId'=>'comment'))}
  assert_raises(PreparationRecord::Invalid) {start_execution(input.merge('actorId'=>@owner.id+1))}
  assert_equal(0,Toybaco::GrowthPostingExecution.count)
 end

 def test_execution_pending_cannot_be_reported_not_sent_or_changed_evidence
  input=execution_fixture;start_execution(input);svc=execution_service(input)
  svc.result!(outcome:'pending',evidence_hash:'a'*64)
  assert_raises(PreparationRecord::Invalid) {svc.result!(outcome:'not_sent',evidence_hash:'b'*64)}
  assert_raises(PreparationRecord::Invalid) {svc.result!(outcome:'pending',evidence_hash:'b'*64)}
  assert_equal('pending',svc.status['state'])
 end
 def test_execution_uncertain_receipt_binds_first_evidence_and_rejects_changed_retry
  input=execution_fixture;start_execution(input);svc=execution_service(input)
  first=svc.result!(outcome:'uncertain',evidence_hash:'a'*64)
  assert_equal('a'*64,first['evidenceHash'])
  assert_equal(first,svc.result!(outcome:'uncertain',evidence_hash:'a'*64))
  assert_equal(first,svc.status)
  assert_raises(PreparationRecord::Invalid) {svc.result!(outcome:'uncertain',evidence_hash:'b'*64)}
  assert_equal(first,svc.status)
  assert_equal('pending',svc.result!(outcome:'pending',evidence_hash:'c'*64)['state'])
  assert_raises(PreparationRecord::Invalid) {svc.result!(outcome:'uncertain',evidence_hash:'a'*64)}
  assert_equal('c'*64,svc.status['evidenceHash'])
 end
 def test_execution_finalize_recovers_when_main_terminal_arrives_first
  input=execution_fixture;start_execution(input);main=execution_service(input)
  main.result!(outcome:'pending',evidence_hash:'a'*64)
  final=input.merge('step'=>'FINALIZE','reservationHash'=>'e'*64,'sequence'=>1,'previousPendingHash'=>'a'*64,'pendingDataHash'=>'b'*64);start_execution(final)
  main.result!(outcome:'published',evidence_hash:'f'*64)
  original=Toybaco::GrowthPostingExecution.find_by(operation_id:Toybaco::Growth::PostingExecutionProtocol.operation_id(input)).attributes
  final_service=execution_service(final)
  assert_raises(PreparationRecord::Invalid) {final_service.result!(outcome:'rejected',evidence_hash:'f'*64)}
  assert_raises(PreparationRecord::Invalid) {final_service.result!(outcome:'published',evidence_hash:'e'*64)}
  assert_equal('started',final_service.status['state'])
  result=final_service.result!(outcome:'published',evidence_hash:'f'*64)
  assert_equal('completed',result['state'])
  assert_equal('f'*64,result['evidenceHash'])
  assert_equal(original,Toybaco::GrowthPostingExecution.find_by(operation_id:Toybaco::Growth::PostingExecutionProtocol.operation_id(input)).attributes)
 end
 def test_execution_uncertain_has_no_expiry_and_allows_only_same_operation_recovery
  input=execution_fixture;start_execution(input);svc=execution_service(input)
  assert_equal('uncertain',svc.result!(outcome:'uncertain',evidence_hash:'a'*64)['state'])
  assert_equal('uncertain',start_execution(input)['state'])
  late=Toybaco::Growth::PostingExecutionV3.new(input,client:@release_provider,environment:{},clock:-> {NOW+366.days})
  assert_equal('uncertain',late.status['state'])
  assert_equal('completed',late.result!(outcome:'rejected',evidence_hash:'b'*64)['state'])
 end
 def test_execution_result_after_insert_failure_rolls_back_both_parent_and_final
  input=execution_fixture;start_execution(input);execution_service(input).result!(outcome:'pending',evidence_hash:'a'*64)
  final=input.merge('step'=>'FINALIZE','reservationHash'=>'e'*64,'sequence'=>1,'previousPendingHash'=>'a'*64,'pendingDataHash'=>'b'*64);start_execution(final)
  callback=-> {raise 'persist failure' if request['step']=='MAIN' && state=='completed'}
  Toybaco::GrowthPostingExecution.set_callback(:update,:after,callback)
  begin
   assert_raises(RuntimeError) {execution_service(final).result!(outcome:'published',evidence_hash:'f'*64)}
  ensure
   Toybaco::GrowthPostingExecution.skip_callback(:update,:after,callback)
  end
  assert_equal('started',execution_service(final).status['state']);assert_equal('pending',execution_service(input).status['state'])
 end
 def test_authority_pointer_and_record_are_atomic_after_update_failure
  prepared=authority_fixture;svc=authority_service
  request={preparation_request_id:prepared['request_id'],authority_id:'b'*64,revision:svc.read(preparation_request_id:prepared['request_id'])['revision']}
  callback=-> {raise 'activation receipt failure' if state=='active'}
  Toybaco::GrowthPostingAuthority.set_callback(:update,:after,callback)
  begin
   assert_raises(RuntimeError) {svc.activate!(**request)}
  ensure
   Toybaco::GrowthPostingAuthority.skip_callback(:update,:after,callback)
  end
  assert_equal(0,Toybaco::GrowthPostingAuthorityCurrent.count)
  assert_equal('pending',Toybaco::GrowthPostingAuthority.first.state)
  assert_equal('active',svc.activate!(**request)['state'])
 end
 def test_authority_pointer_revocation_rollback_preserves_epoch
  activate_fixture
  before=Toybaco::GrowthPostingAuthorityCurrent.first.attributes
  @account.with_lock do
   Toybaco::Growth::PostingPrincipal.rotate!(@account.id,user_ids:[@owner.id],now:NOW)
   raise ActiveRecord::Rollback
  end
  assert_equal(before,Toybaco::GrowthPostingAuthorityCurrent.first.attributes)
 end
 def test_execution_protocol_vector_and_signed_request_rejects_wrong_direction_purpose_replay_and_duplicates
  vector=JSON.parse(File.read(File.join(__dir__, 'fixtures/posting-authority-protocol-v1.json')))
  proto=Toybaco::Growth::PostingExecutionProtocol;config=proto.configuration(authority_environment)
  fixed=vector.fetch('execution').fetch('body').fetch('execution')
  assert_equal(vector.fetch('operationId'),proto.operation_id(fixed))
  assert_equal(vector.fetch('executionRequestHash'),PreparationRecord.digest(fixed))
  vector.each_pair do |kind,item|
   next unless %w[authority execution].include?(kind)
   protocol=kind=='authority' ? Toybaco::Growth::PostingAuthorityProtocol : proto
   key=OpenSSL::HMAC.digest('SHA256','unusable-posting-authority-vector-fixture',protocol::PURPOSE)
   assert_equal(item.fetch('signature'),protocol.signature(item.fetch('raw'),key:key,now:Time.at(vector.fetch('stamp')),direction:'POST'))
  end
  input=execution_fixture
  payload={'version'=>3,'issuer'=>config[:origin],'audience'=>config[:issuer],'mode'=>'test','operation'=>'status','execution'=>input}
  raw=JSON.generate(payload);signed=proto.signature(raw,key:config[:key],now:NOW,direction:'POST')
  assert_equal(payload,proto.request!(raw,header:signed,config:config,now:NOW))
  assert_raises(proto::Invalid) {proto.request!(raw,header:signed,config:config,now:NOW+61)}
  wrong=proto.signature(raw,key:config[:key],now:NOW,direction:'RESPONSE')
  assert_raises(proto::Invalid) {proto.request!(raw,header:wrong,config:config,now:NOW)}
  duplicate=raw.sub('"version":3','"version":3,"version":3')
  signed=proto.signature(duplicate,key:config[:key],now:NOW,direction:'POST')
  assert_raises(proto::Invalid) {proto.request!(duplicate,header:signed,config:config,now:NOW)}
 end
 def test_execution_new_start_rechecks_principal_after_stripe_and_refuses_outer_transaction
  input=execution_fixture
  provider=->(*) {@account.with_lock {Toybaco::Growth::PostingPrincipal.rotate!(@account.id,user_ids:[@owner.id],now:NOW)}}
  Toybaco::Growth::PostingExecutionAuthority.stub(:verify_provider!,provider) do
   assert_raises(PreparationRecord::Invalid) {execution_service(input).start!}
  end
  assert_equal(0,Toybaco::GrowthPostingExecution.count)
  @account.with_lock {assert_raises(PreparationRecord::Invalid) {execution_service(input).start!}}
 end
 def with_execution_http
  previous=authority_environment.keys.to_h { |key| [key,ENV[key]] }
  authority_environment.each { |key,value| ENV[key]=value }
  session=ActionDispatch::Integration::Session.new(Rails.application)
  session.host! 'app.staging.toybaco.jp'
  Toybaco::Checkout::Client.stub(:new,@release_provider) {yield session}
 ensure
  previous&.each { |key,value| ENV[key]=value }
 end
 def signed_execution_http(session,input,operation,extra={})
  protocol=Toybaco::Growth::PostingExecutionProtocol
  config=protocol.configuration(authority_environment)
  payload={'version'=>3,'issuer'=>config[:origin],'audience'=>config[:issuer],'mode'=>config[:mode],'operation'=>operation,'execution'=>input}.merge(extra)
  raw=JSON.generate(payload)
  header=protocol.signature(raw,key:config[:key],now:Time.now.utc,direction:'POST')
  session.post protocol::PATH,params:raw,headers:{'Content-Type'=>'application/json',protocol::HEADER=>header}
  assert_equal(200,session.response.status)
  assert_equal('no-store',session.response.headers['Cache-Control'])
  actual=session.response.body
  assert_equal(protocol.signature(actual,key:config[:key],now:Time.now.utc,direction:'RESPONSE'),session.response.headers[protocol::HEADER])
  body=JSON.parse(actual)
  assert_equal(Digest::SHA256.hexdigest(raw),body['request_sha256'])
  refute(body.fetch('execution').fetch('execute'))
  body.fetch('execution')
 end
 def test_execution_signed_real_http_start_status_uncertain_and_flag_off_result
  input=execution_fixture
  with_execution_http do |session|
   assert_equal('started',signed_execution_http(session,input,'start')['state'])
   assert_equal('started',signed_execution_http(session,input,'status')['state'])
   result=signed_execution_http(session,input,'result',{'outcome'=>'uncertain','evidenceHash'=>'a'*64})
   assert_equal('a'*64,result['evidenceHash'])
   ENV['TOYBACO_POSTING_EXECUTION_ENABLED']='false'
   result=signed_execution_http(session,input,'result',{'outcome'=>'rejected','evidenceHash'=>'b'*64})
   assert_equal('completed',result['state'])
   assert_equal(1,Toybaco::GrowthPostingExecution.where(account_id:@account.id).count)
  end
 end
 def test_execution_real_http_rejects_browser_credentials_bad_signature_and_unknown_fields
  input=execution_fixture
  with_execution_http do |session|
   protocol=Toybaco::Growth::PostingExecutionProtocol;config=protocol.configuration(authority_environment)
   raw=JSON.generate({'version'=>3,'issuer'=>config[:origin],'audience'=>config[:issuer],'mode'=>config[:mode],'operation'=>'start','execution'=>input,'execute'=>true})
   session.post protocol::PATH,params:raw,headers:{'Content-Type'=>'application/json','Origin'=>'https://app.staging.toybaco.jp'}
   assert_equal(403,session.response.status)
   signature=protocol.signature(raw,key:config[:key],now:Time.now.utc,direction:'POST')
   session.post protocol::PATH,params:raw,headers:{'Content-Type'=>'application/json',protocol::HEADER=>signature}
   assert_equal(403,session.response.status)
   assert_equal('',session.response.body)
   assert_equal(0,Toybaco::GrowthPostingExecution.where(account_id:@account.id).count)
  end
 end
 def test_execution_multistage_finalize_keeps_main_pending_until_terminal_stage
  input=execution_fixture;start_execution(input);main=execution_service(input)
  main.result!(outcome:'pending',evidence_hash:'a'*64)
  first=input.merge('step'=>'FINALIZE','sequence'=>1,'previousPendingHash'=>'a'*64,'pendingDataHash'=>'b'*64,'reservationHash'=>'e'*64)
  start_execution(first)
  assert_equal('completed',execution_service(first).result!(outcome:'pending',evidence_hash:'c'*64)['state'])
  assert_equal('pending',execution_service(first).status['outcome'])
  assert_equal('pending',main.status['state'])
  second=first.merge('sequence'=>2,'previousPendingHash'=>'c'*64,'pendingDataHash'=>'d'*64,'reservationHash'=>'f'*64)
  assert_raises(PreparationRecord::Invalid) {start_execution(second.merge('previousPendingHash'=>'a'*64))}
  start_execution(second)
  assert_equal('completed',execution_service(second).result!(outcome:'pending',evidence_hash:'d'*64)['state'])
  assert_equal('pending',main.status['state'])
  third=first.merge('sequence'=>3,'previousPendingHash'=>'d'*64,'pendingDataHash'=>'e'*64,'reservationHash'=>'a'*64)
  start_execution(third)
  execution_service(third).result!(outcome:'published',evidence_hash:'f'*64)
  assert_equal('published',main.status['outcome'])
  assert_equal('f'*64,main.status['evidenceHash'])
  assert_equal('pending',execution_service(first).result!(outcome:'pending',evidence_hash:'c'*64)['outcome'])
  assert_equal('completed',main.result!(outcome:'pending',evidence_hash:'a'*64)['state'])
  assert_equal(4,Toybaco::GrowthPostingExecution.count)
  assert_raises(PreparationRecord::Invalid) {start_execution(third.merge('sequence'=>4,'previousPendingHash'=>'f'*64))}
 end
 def test_execution_multistage_rejects_missing_started_uncertain_and_terminal_previous_stage
  input=execution_fixture;start_execution(input);execution_service(input).result!(outcome:'pending',evidence_hash:'a'*64)
  first=input.merge('step'=>'FINALIZE','sequence'=>1,'previousPendingHash'=>'a'*64,'pendingDataHash'=>'b'*64,'reservationHash'=>'e'*64)
  second=first.merge('sequence'=>2,'previousPendingHash'=>'c'*64,'pendingDataHash'=>'c'*64,'reservationHash'=>'f'*64)
  assert_raises(PreparationRecord::Invalid) {start_execution(second)}
  start_execution(first)
  assert_raises(PreparationRecord::Invalid) {start_execution(second)}
  execution_service(first).result!(outcome:'uncertain',evidence_hash:'d'*64)
  assert_raises(PreparationRecord::Invalid) {start_execution(second)}
  execution_service(first).result!(outcome:'rejected',evidence_hash:'c'*64)
  assert_raises(PreparationRecord::Invalid) {start_execution(second)}
  assert_equal(2,Toybaco::GrowthPostingExecution.count)
 end
 def test_execution_multistage_validates_fixed_sequence_fields_and_binds_pending_data
  input=execution_fixture
  [input.except('sequence'),input.merge('sequence'=>1),input.merge('previousPendingHash'=>'a'*64),input.merge('pendingDataHash'=>'a'*64)].each do |bad|
   assert_raises(PreparationRecord::Invalid) {execution_service(bad)}
  end
  start_execution(input);execution_service(input).result!(outcome:'pending',evidence_hash:'a'*64)
  first=input.merge('step'=>'FINALIZE','sequence'=>1,'previousPendingHash'=>'a'*64,'pendingDataHash'=>'b'*64,'reservationHash'=>'e'*64)
  [0,10_001,1.5,'1'].each { |bad| assert_raises(PreparationRecord::Invalid) {execution_service(first.merge('sequence'=>bad))} }
  start_execution(first)
  assert_raises(PreparationRecord::Invalid) {start_execution(first.merge('pendingDataHash'=>'c'*64))}
  assert_equal('started',execution_service(first).status['state'])
 end
 def test_execution_multistage_late_pending_finishes_own_stage_without_reopening_terminal_main
  input=execution_fixture;start_execution(input);main=execution_service(input);main.result!(outcome:'pending',evidence_hash:'a'*64)
  first=input.merge('step'=>'FINALIZE','sequence'=>1,'previousPendingHash'=>'a'*64,'pendingDataHash'=>'b'*64,'reservationHash'=>'e'*64)
  start_execution(first);main.result!(outcome:'published',evidence_hash:'f'*64)
  receipt=main.status
  assert_equal('completed',execution_service(first).result!(outcome:'pending',evidence_hash:'c'*64)['state'])
  assert_equal(receipt,main.status)
  assert_raises(PreparationRecord::Invalid) {start_execution(first.merge('sequence'=>2,'previousPendingHash'=>'c'*64))}
 end

end
