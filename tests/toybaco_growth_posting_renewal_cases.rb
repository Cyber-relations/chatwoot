# frozen_string_literal: true

require Rails.root.join('lib/toybaco/growth/posting_renewal')
require Rails.root.join('lib/toybaco/growth/ordinary_renewal_due_evidence')
require Rails.root.join('lib/toybaco/growth/billing_receipt')
require Rails.root.join('lib/toybaco/growth/renewal_ingress_verification')

# Prepend after the authority runtime fixture. Stripe and the future Postiz
# adapter are fixtures; the Rails records, locks, signatures and readers are real.
module ToybacoPostingRenewalRuntimeCases
 N3 = Toybaco::Growth
 PreparationRecord = Toybaco::Growth::PostingPreparationRecord
 def n3_now = @n3_now || self.class::NOW
 def n3_time(seconds)
  @n3_now=Time.at(seconds).utc
  travel_to @n3_now
 end
 def n3_mutate(values)
  @account.reload.update!(internal_attributes:@account.internal_attributes.merge(values))
  @account.reload
 end
 def n3i_seed_authority
  _,request,=activate_fixture
  {'authorityId'=>request[:authority_id]}
 end
 def teardown
  if @renewal_test_used
   Toybaco::GrowthPostingRenewal.where(account_id:@account.id).delete_all
   Toybaco::GrowthPostingStop.where(account_id:@account.id).delete_all
   operations=Toybaco::RenewalOperation.where(subscription_id:@n3_subscription_id)
   operations.update_all(first_fact_id:nil,first_failed_at:nil,due_at:nil,state:'unverified')
   Toybaco::RenewalInvoiceFact.where(subscription_id:@n3_subscription_id).delete_all
   operations.delete_all
   Toybaco::BillingEvent.where(reference_id:@n3_subscription_id).delete_all
   Toybaco::SubscriptionSyncRequest.where(subscription_id:@n3_subscription_id).delete_all
   @n3_old_mode.nil? ? ENV.delete('TOYBACO_STRIPE_MODE') : ENV['TOYBACO_STRIPE_MODE']=@n3_old_mode
  end
  super
 end
 def n3_client
  test=self
  Object.new.tap do |client|
   client.define_singleton_method(:retrieve_subscription) do |id|
    raise 'wrong subscription' unless id==test.instance_variable_get(:@n3_subscription_id)
    raise 'Stripe inside Account transaction' if Account.connection.transaction_open?
    test.instance_variable_get(:@n3_provider).deep_dup
   end
  end
 end
  def n3_subscription(starts, ends, invoice_id, paid:, paid_at: nil)
    amount = Toybaco::PlanCatalog.default.definition(@n3_contract['plan_id'],@n3_contract['plan_version']).fetch('cycles').fetch(@n3_contract['cycle']).fetch('amount')
    line = {'id' => 'il_fixture', 'type' => 'subscription', 'subscription' => @n3_subscription_id,
      'subscription_item' => @n3_contract['subscription_item_id'], 'proration' => false, 'price' => {'id' => @n3_contract['stripe_price_id']},
      'quantity' => 1, 'amount' => amount, 'currency' => 'jpy', 'period' => {'start' => starts, 'end' => ends}, 'discount_amounts' => []}
    invoice = {'id' => invoice_id, 'subscription' => @n3_subscription_id, 'customer' => @n3_customer_id, 'livemode' => false,
      'status' => paid ? 'paid' : 'open', 'billing_reason' => 'subscription_cycle', 'collection_method' => 'charge_automatically',
      'currency' => 'jpy', 'amount_remaining' => paid ? 0 : amount, 'amount_due' => amount, 'amount_paid' => paid ? amount : 0,
      'subtotal' => amount, 'starting_balance' => 0, 'amount_shipping' => 0, 'pre_payment_credit_notes_amount' => 0,
      'post_payment_credit_notes_amount' => 0, 'discounts' => [], 'total_discount_amounts' => [],
      'status_transitions' => {'paid_at' => paid_at}, 'lines' => {'has_more' => false, 'data' => [line]}}
    {'id' => @n3_subscription_id, 'customer' => @n3_customer_id, 'livemode' => false,
      'status' => paid ? 'active' : 'past_due', 'collection_method' => 'charge_automatically', 'pause_collection' => nil,
      'pending_update' => nil, 'schedule' => nil, 'cancel_at_period_end' => false, 'billing_cycle_anchor' => @n3_previous_start,
      'items' => {'has_more' => false, 'data' => [{'id' => @n3_contract['subscription_item_id'], 'quantity' => 1, 'price' => {'id' => @n3_contract['stripe_price_id']},
      'current_period_start' => starts, 'current_period_end' => ends}]}, 'metadata' => {'toybaco_purchase_nonce' => @n3_nonce},
      'latest_invoice' => invoice}
  end
 def n3i_client
  test=self
  client=n3_client
  client.define_singleton_method(:retrieve_invoice) do |id|
   raise 'Stripe in Account transaction' if Account.connection.transaction_open?
   invoices=[test.instance_variable_get(:@n3_previous_invoice),test.instance_variable_get(:@n3_provider)['latest_invoice']]
   invoices.find { |v| v['id']==id }.deep_dup || raise('wrong invoice')
  end
  client.define_singleton_method(:list_customer_subscriptions) { |_, **| {'data'=>[test.instance_variable_get(:@n3_provider).deep_dup], 'has_more'=>false} }
  client.define_singleton_method(:list_customer_invoices) { |_, **| {'data'=>[test.instance_variable_get(:@n3_provider)['latest_invoice'].deep_dup], 'has_more'=>false} }
  client.define_singleton_method(:pending_customer_invoice_items) { |_| {'data'=>[], 'has_more'=>false} }
  client.define_singleton_method(:list_invoice_payments) { |_, **| {'data'=>[], 'has_more'=>false} }
  client
 end
 def n3i_fact
  raw={'id'=>"evt_n3#{SecureRandom.hex(10)}",'object'=>'event','type'=>'invoice.payment_failed','livemode'=>false,'created'=>@n3_boundary,
   'data'=>{'object'=>{'id'=>'in_failed','object'=>'invoice','subscription'=>@n3_subscription_id,'customer'=>@n3_customer_id,'billing_reason'=>'subscription_cycle','attempt_count'=>1}}}
  now=n3_now.to_i; secret='whsec_fixture12345678901234567890'; json=JSON.generate(raw)
  sig="t=#{now},v1=#{OpenSSL::HMAC.hexdigest('SHA256',secret,"#{now}.#{json}")}"
  verified=N3::PaymentSignature.verify!(json,sig,environment:{'TOYBACO_STRIPE_PACK_WEBHOOK_SECRET'=>secret})
  event=N3::BillingReceipt.accept!(N3::BillingSnapshot.new(verified).read,now:n3_now)
  N3::RenewalIngressVerification.new(event,client:n3i_client,now:n3_now).record!
  Toybaco::RenewalOperation.find_by!(invoice_id:'in_failed')
 end
 def n3i_fixture(paid:false)
  @renewal_test_used=true
  @n3_old_mode=ENV['TOYBACO_STRIPE_MODE'];ENV['TOYBACO_STRIPE_MODE']='test'
  input=n3i_seed_authority
  @n3_contract=Toybaco::Entitlements.contract_for(@account)
  attrs=@account.reload.internal_attributes
  @n3_subscription_id=attrs['toybaco_subscription_id'];@n3_customer_id=attrs['toybaco_stripe_customer_id']
  @n3_nonce=attrs.dig(N3::PurchaseIntent::KEY,'nonce')
  coverage=attrs.fetch(N3::PaidPeriod::KEY)
  @n3_boundary=coverage['term_end'];@n3_previous_start=coverage['term_start']
  @n3_previous_invoice=n3_subscription(coverage['term_start'],coverage['term_end'],coverage['invoice_id'],paid:true,paid_at:coverage['paid_at'])['latest_invoice']
  n3_time(@n3_boundary+3600)
  @n3_provider=n3_subscription(@n3_boundary,@n3_boundary+30.days.to_i,'in_failed',paid:paid,paid_at:paid ? @n3_boundary+60 : nil)
  operation=n3i_fact
  n3_mutate('toybaco_subscription_status'=>paid ? 'active' : 'past_due')
  N3::PaidPeriod.new(@account,now:n3_now).observe!(@n3_provider) if paid
  [input,operation]
 end
 def n3i_service(transport:nil)
  N3::PostingRenewal.new(@account,@owner,client:n3i_client,environment:authority_environment.merge('TOYBACO_POSTING_RENEWAL_ENABLED'=>'true'),clock:-> {n3_now},transport:transport) { preparation_database }
 end
 def n3i_prepare(input,operation,kind:'renewal_grace',request:'d'*64)
  n3i_service.prepare!(kind:kind,request_id:request,source_authority_id:input['authorityId'],operation_id:operation&.id)
 end
 def n3i_transport(&hook)
  test=self
  Object.new.tap do |adapter|
   adapter.define_singleton_method(:verified_protocol) {'toybaco-posting-renewal-v1'}
   adapter.define_singleton_method(:call) do |payload|
    raise 'HTTP in Account transaction' if Account.connection.transaction_open?
    target=payload['targetAuthority']
    pointer={'organizationId'=>target['organizationId'],'authorityId'=>target['authorityId'],'generation'=>'1','epoch'=>'11111111-1111-4111-8111-111111111111','state'=>payload['phase']=='prepare' ? 'pending' : 'ready'}
    test.instance_variable_set(:@authority_pointer,pointer)
    result=payload.slice('version','protocol','operationId','sourceAuthorityId','targetAuthorityId','targetAuthorityHash','sourcePointerHash','execute')
    result.merge!('receiptHash'=>PreparationRecord.digest(['postiz',payload['operationId']]),'rootManifestHash'=>PreparationRecord.digest([]),'requestHash'=>PreparationRecord.digest(payload),'targetPointerHash'=>PreparationRecord.digest(pointer.except('state')),'state'=>payload['phase']=='prepare' ? 'prepared':'ready')
    hook&.call(payload,result)
    result
   end
  end
 end
 def test_n3i_grace_prepare_is_immutable_nonexecuting_and_requires_protocol
  input,operation=n3i_fixture
  before=Toybaco::GrowthPostingAuthority.first.attributes
  result=n3i_prepare(input,operation)
  assert_equal ['prepared',false],[result['state'],result['execute']]
  row=Toybaco::GrowthPostingRenewal.first
  assert_equal @n3_boundary+7.days.to_i,row.receipt.dig('evidence','expires_at')
  assert_equal before,Toybaco::GrowthPostingAuthority.first.attributes
  assert_equal result,n3i_prepare(input,operation)
  assert_raises(N3::PostingRenewal::ProtocolUnavailable){n3i_service.deliver!(request_id:row.request_id)}
  assert_equal 'prepared',row.reload.state
 end
 def test_n3i_paid_after_failure_key_is_not_an_activation_exception
  input,operation=n3i_fixture(paid:true)
  result=n3i_prepare(input,operation,kind:'renewal_paid')
  assert_equal 'prepared',result['state']
  assert_equal @n3_provider['latest_invoice']['lines']['data'][0]['period']['end'],Toybaco::GrowthPostingRenewal.first.receipt.dig('evidence','expires_at')
 end
 def test_n3i_internal_handoff_creates_new_epoch_and_validates_explicit_typed_authority
  input,operation=n3i_fixture
  old=Toybaco::GrowthPostingAuthority.first.attributes.deep_dup
  pointer=Toybaco::GrowthPostingAuthorityCurrent.first.attributes.deep_dup
  result=n3i_prepare(input,operation)
  ready=n3i_service(transport:n3i_transport).deliver!(request_id:result['request_id'])
  assert_equal ['ready',false],[ready['state'],ready['execute']]
  assert_equal old,Toybaco::GrowthPostingAuthority.find_by!(authority_id:input['authorityId']).attributes
  current=Toybaco::GrowthPostingAuthorityCurrent.first
  assert_equal pointer['generation']+1,current.generation
  refute_equal pointer['epoch'],current.epoch
  target=Toybaco::GrowthPostingAuthority.find_by!(authority_id:ready['target_authority_id'])
  assert_equal 2,target.receipt['version']
  assert_equal target.receipt,N3::PostingAuthorityRecord.validate!(target,now:n3_now)
  assert_equal ready,n3i_service(transport:n3i_transport).deliver!(request_id:result['request_id'])
 end
 def test_n3i_prepare_response_loss_keeps_phase_fence_and_recovers_same_request
  input,operation=n3i_fixture
  result=n3i_prepare(input,operation)
  failed=false
  adapter=n3i_transport do |payload,_|
   if payload['phase']=='prepare'&&!failed
    failed=true;raise Timeout::Error
   end
  end
  service=n3i_service(transport:adapter)
  assert_raises(Timeout::Error){service.deliver!(request_id:result['request_id'])}
  row=Toybaco::GrowthPostingRenewal.first
  assert_equal 'transferring',row.state
  assert_equal input['authorityId'],Toybaco::GrowthPostingAuthorityCurrent.first.authority_id
  assert_raises(N3::PostingExecutionContext::Busy){@account.update!(status: :suspended)}
  assert_equal 'active',@account.reload.status
  assert_raises(N3::PostingExecutionContext::Busy){@account.with_lock {N3::PostingStopContext.guard_admission!(@account.id)}}
  assert_equal 'ready',service.deliver!(request_id:result['request_id'])['state']
  assert_equal 2,Toybaco::GrowthPostingAuthority.count
 end
 def test_n3i_confirm_response_loss_retains_current_epoch_and_recovers
  input,operation=n3i_fixture
  result=n3i_prepare(input,operation)
  failed=false
  adapter=n3i_transport do |payload,_|
   if payload['phase']=='confirm'&&!failed
    failed=true;raise Timeout::Error
   end
  end
  service=n3i_service(transport:adapter)
  assert_raises(Timeout::Error){service.deliver!(request_id:result['request_id'])}
  assert_equal 'applied',Toybaco::GrowthPostingRenewal.first.state
  pointer=Toybaco::GrowthPostingAuthorityCurrent.first.attributes
  assert_equal 'ready',service.deliver!(request_id:result['request_id'])['state']
  assert_equal pointer,Toybaco::GrowthPostingAuthorityCurrent.first.attributes
 end
 def test_n3i_local_commit_failure_rolls_back_pointer_and_target_state_after_remote_commit
  input,operation=n3i_fixture
  result=n3i_prepare(input,operation)
  hook=-> {raise IOError if state=='applied'}
  Toybaco::GrowthPostingRenewal.set_callback(:update,:after,hook)
  assert_raises(IOError){n3i_service(transport:n3i_transport).deliver!(request_id:result['request_id'])}
  assert_equal 'transferring',Toybaco::GrowthPostingRenewal.first.state
  assert_equal input['authorityId'],Toybaco::GrowthPostingAuthorityCurrent.first.authority_id
  target=Toybaco::GrowthPostingAuthority.find_by!(authority_id:result['target_authority_id'])
  assert_equal 'pending',target.state
 ensure
  Toybaco::GrowthPostingRenewal.skip_callback(:update,:after,hook) if hook
 end
 def test_n3i_seven_day_exact_boundary_and_no_duplicate_invoice_rearming
  input,operation=n3i_fixture
  n3_time(operation.due_at.to_i-1)
  result=n3i_prepare(input,operation)
  assert_equal operation.due_at.to_i,Toybaco::GrowthPostingRenewal.first.receipt.dig('evidence','expires_at')
  assert_raises(ActiveRecord::RecordNotUnique){n3i_prepare(input,operation,request:'e'*64)}
  n3_time(operation.due_at.to_i)
  assert_equal result,n3i_prepare(input,operation)
  assert_raises(PreparationRecord::Invalid){n3i_prepare(input,operation,request:'f'*64)}
  assert_raises(PreparationRecord::Invalid){n3i_service(transport:n3i_transport).deliver!(request_id:result['request_id'])}
  assert_equal 'prepared',Toybaco::GrowthPostingRenewal.first.state
 end
 def test_n3i_grace_payment_race_does_not_convert_inflight_receipt_or_rearm
  input,operation=n3i_fixture
  result=n3i_prepare(input,operation)
  adapter=n3i_transport do |_,_|
   @n3_provider=n3_subscription(@n3_boundary,@n3_boundary+30.days.to_i,'in_failed',paid:true,paid_at:n3_now.to_i)
  end
  assert_raises(PreparationRecord::Invalid){n3i_service(transport:adapter).deliver!(request_id:result['request_id'])}
  assert_equal 'transferring',Toybaco::GrowthPostingRenewal.first.state
  assert_equal input['authorityId'],Toybaco::GrowthPostingAuthorityCurrent.first.authority_id
  assert_raises(N3::PostingExecutionContext::Busy){@account.update!(status: :suspended)}
 end
 def test_n3i_principal_aba_rejects_prepared
  input,operation=n3i_fixture
  result=n3i_prepare(input,operation)
  @account.with_lock{N3::PostingPrincipal.rotate!(@account.id,user_ids:[@owner.id],now:n3_now)}
  assert_raises(N3::PostingExecutionContext::Invalid){n3i_service(transport:n3i_transport).deliver!(request_id:result['request_id'])}
  assert_equal 'prepared',Toybaco::GrowthPostingRenewal.first.state
 end
 def test_n3i_mixed_invoice_does_not_borrow_n1_observed_fact
  input,operation=n3i_fixture
  assert_equal 'observed_failure',operation.state
  @n3_provider['latest_invoice']['lines']['data'] << @n3_provider['latest_invoice']['lines']['data'].first.merge('id'=>'il_extra')
  assert_raises(PreparationRecord::Invalid){n3i_prepare(input,operation)}
  refute Toybaco::GrowthPostingRenewal.exists?
 end
 def test_n3i_source_current_aba_prevents_transfer
  input,operation=n3i_fixture
  result=n3i_prepare(input,operation)
  @account.with_lock do
   ptr=N3::PostingAuthorityState.current(@account.id,now:n3_now)
   N3::PostingAuthorityState.assign!(@account.id,'f'*64,expected:N3::PostingAuthorityState.fingerprint(ptr),now:n3_now)
   ptr=N3::PostingAuthorityState.current(@account.id,now:n3_now)
   N3::PostingAuthorityState.assign!(@account.id,input['authorityId'],expected:N3::PostingAuthorityState.fingerprint(ptr),now:n3_now)
  end
  assert_raises(PreparationRecord::Invalid){n3i_service(transport:n3i_transport).deliver!(request_id:result['request_id'])}
 end
 def test_n3i_signed_fact_mutation_rejected_before_provider_use
  input,operation=n3i_fixture
  Toybaco::BillingEvent.where(id:Toybaco::BillingEvent.first.id).update_all(payload_digest:'a'*64)
  assert_raises(N3::PaymentSignature::Invalid){n3i_prepare(input,operation)}
  refute Toybaco::GrowthPostingRenewal.exists?
 end
 def test_n3i_prepared_marker_survives_business_deletion
  input,operation=n3i_fixture
  n3i_prepare(input,operation)
  c=Account.connection
  assert_equal true,c.select_value("SELECT EXISTS (SELECT 1 FROM toybaco_durable_capability_acceptances WHERE capability='posting-renewal-v1')")
  Toybaco::GrowthPostingRenewal.delete_all
  assert_equal true,c.select_value("SELECT EXISTS (SELECT 1 FROM toybaco_durable_capability_acceptances WHERE capability='posting-renewal-v1')")
  assert_raises(ActiveRecord::StatementInvalid){c.execute("DELETE FROM toybaco_durable_capability_acceptances WHERE capability='posting-renewal-v1'")}
 end
 def test_n3i_three_month_paid_continuations_preserve_original_schedule_identity_without_depth_limit
  input,operation=n3i_fixture(paid:true)
  # Retain a real first-failure key after payment, matching the observed fact.
  n3_mutate(N3::RenewalGrace::FAILURE_KEY=>{'subscription_id'=>@n3_subscription_id,'invoice_id'=>'in_failed','first_failed_at'=>operation.first_failed_at.to_i,
   'grace_ends_at'=>operation.due_at.to_i,'term_start'=>@n3_boundary,'term_end'=>@n3_boundary+30.days.to_i})
  original=Toybaco::GrowthPostingAuthority.first.receipt.deep_dup
  result=n3i_prepare(input,operation,kind:'renewal_paid')
  3.times do |index|
   ready=n3i_service(transport:n3i_transport).deliver!(request_id:result['request_id'])
   current=Toybaco::GrowthPostingAuthority.find_by!(authority_id:ready['target_authority_id'])
   assert_equal original['preparation_request_id'],current.preparation_request_id
   assert_equal original['scheduled_posts_per_account'],current.receipt['scheduled_posts_per_account']
   break if index==2
   @n3_previous_invoice=@n3_provider['latest_invoice'].deep_dup
   starts=@n3_previous_invoice['lines']['data'][0]['period']['end']
   n3_time(starts+60)
   @n3_provider=n3_subscription(starts,starts+30.days.to_i,"in_month#{index}",paid:true,paid_at:starts)
   N3::PaidPeriod.new(@account,now:n3_now).observe!(@n3_provider)
   result=n3i_service.prepare!(kind:'renewal_paid',request_id:(index==0 ? 'e':'f')*64,source_authority_id:ready['target_authority_id'])
  end
  assert_equal 4,Toybaco::GrowthPostingAuthority.count
  assert_equal 4,Toybaco::GrowthPostingAuthorityCurrent.first.generation
  assert_equal original,Toybaco::GrowthPostingAuthority.find_by!(authority_id:input['authorityId']).receipt
 end
 def test_n3i_grace_to_paid_new_record_keeps_original_invoice_and_failure_deadline
  input,operation=n3i_fixture
  grace=n3i_prepare(input,operation)
  ready=n3i_service(transport:n3i_transport).deliver!(request_id:grace['request_id'])
  before=Toybaco::GrowthPostingRenewal.first.receipt.deep_dup
  @n3_provider=n3_subscription(@n3_boundary,@n3_boundary+30.days.to_i,'in_failed',paid:true,paid_at:n3_now.to_i)
  n3_mutate('toybaco_subscription_status'=>'active')
  N3::PaidPeriod.new(@account,now:n3_now).observe!(@n3_provider)
  paid=n3i_service.prepare!(kind:'renewal_paid',request_id:'e'*64,source_authority_id:ready['target_authority_id'],operation_id:operation.id)
  assert_equal 'ready',n3i_service(transport:n3i_transport).deliver!(request_id:paid['request_id'])['state']
  assert_equal before,Toybaco::GrowthPostingRenewal.find_by!(kind:'renewal_grace').receipt
  assert_equal 3,Toybaco::GrowthPostingAuthorityCurrent.first.generation
 end
 def test_n3i_unresolved_execution_blocks_transfer_without_cancelling_it
  input,operation=n3i_fixture
  result=n3i_prepare(input,operation)
  execution=Toybaco::GrowthPostingExecution.create!(account_id:@account.id,operation_id:'8'*64,identity_hash:'9'*64,
   request:{'version'=>3},request_hash:'7'*64,state:'uncertain',uncertain_evidence_hash:'6'*64,started_at:n3_now,created_at:n3_now,updated_at:n3_now)
  assert_raises(N3::PostingExecutionContext::Busy){n3i_service(transport:n3i_transport).deliver!(request_id:result['request_id'])}
  assert_equal ['prepared','uncertain'],[Toybaco::GrowthPostingRenewal.first.state,execution.reload.state]
  assert_equal input['authorityId'],Toybaco::GrowthPostingAuthorityCurrent.first.authority_id
 end
 def test_n3i_applied_pointer_aba_is_rejected_even_when_authority_id_returns
  input,operation=n3i_fixture
  result=n3i_prepare(input,operation)
  adapter=n3i_transport {|payload,_| raise Timeout::Error if payload['phase']=='confirm'}
  assert_raises(Timeout::Error){n3i_service(transport:adapter).deliver!(request_id:result['request_id'])}
  row=Toybaco::GrowthPostingRenewal.first
  @account.with_lock do
   pointer=N3::PostingAuthorityState.current(@account.id,now:n3_now)
   N3::PostingAuthorityState.assign!(@account.id,row.target_authority_id,expected:N3::PostingAuthorityState.fingerprint(pointer),now:n3_now)
  end
  assert_raises(PreparationRecord::Invalid){n3i_service(transport:n3i_transport).deliver!(request_id:result['request_id'])}
  assert_equal 'applied',row.reload.state
 end
 def test_n3i_pending_stop_and_manual_suspension_block_new_preparation
  input,operation=n3i_fixture
  before=@account.internal_attributes.deep_dup
  n3_mutate('toybaco_billing_suspended'=>true)
  assert_raises(PreparationRecord::Invalid){n3i_prepare(input,operation)}
  @account.update!(internal_attributes:before)
  request={'contract_hash'=>N3::PostingExecutionContext.contract_hash(@account),'target_hash'=>'8'*64}
  N3::PostingStop.new(@account.id,operation_id:'9'*64,request:request,environment:{'TOYBACO_POSTING_STOP_ENABLED'=>'true'},now:n3_now).request!
  assert_raises(PreparationRecord::Invalid){n3i_prepare(input,operation)}
  refute Toybaco::GrowthPostingRenewal.exists?
 end
 def test_n3i_new_contract_or_pending_plan_change_cannot_use_ordinary_receipt
  input,operation=n3i_fixture
  @n3_provider['schedule']='sub_sched_future'
  assert_raises(PreparationRecord::Invalid){n3i_prepare(input,operation)}
  @n3_provider['schedule']=nil
  @n3_provider['metadata']['toybaco_purchase_nonce']='a'*48
  assert_raises(PreparationRecord::Invalid){n3i_prepare(input,operation)}
  refute Toybaco::GrowthPostingRenewal.exists?
 end
 def test_n3i_provider_inflight_payment_rejects_grace
  input,operation=n3i_fixture
  @n3_provider['latest_invoice']['payment_intent']='pi_processing'
  client=n3i_client
  customer=@n3_customer_id
  client.define_singleton_method(:retrieve_payment_intent){|id| {'id'=>id,'customer'=>customer,'livemode'=>false,'currency'=>'jpy','status'=>'processing','amount_received'=>0} }
  svc=n3i_service
  svc.instance_variable_set(:@client,client)
  assert_raises(N3::RenewalPayments::Unresolved,PreparationRecord::Invalid){svc.prepare!(kind:'renewal_grace',request_id:'d'*64,source_authority_id:input['authorityId'],operation_id:operation.id)}
  refute Toybaco::GrowthPostingRenewal.exists?
 end
 def test_n3i_receipt_insert_callback_failure_rolls_back_without_new_authority
  input,operation=n3i_fixture
  hook=-> {raise IOError}
  Toybaco::GrowthPostingRenewal.set_callback(:create,:after,hook)
  assert_raises(IOError){n3i_prepare(input,operation)}
  assert_equal 1,Toybaco::GrowthPostingAuthority.count
  refute Toybaco::GrowthPostingRenewal.exists?
 ensure
  Toybaco::GrowthPostingRenewal.skip_callback(:create,:after,hook) if hook
 end
 def test_n3i_flag_off_outer_transaction_and_different_actor_fail_closed
  input,operation=n3i_fixture
  svc=n3i_service
  svc.instance_variable_set(:@environment,authority_environment)
  assert_raises(PreparationRecord::Invalid){svc.prepare!(kind:'renewal_grace',request_id:'d'*64,source_authority_id:input['authorityId'],operation_id:operation.id)}
  @account.with_lock{assert_raises(PreparationRecord::Invalid){n3i_prepare(input,operation)}}
  svc=n3i_service
  svc.instance_variable_set(:@user,nil)
  assert_raises(PreparationRecord::Invalid){svc.prepare!(kind:'renewal_grace',request_id:'d'*64,source_authority_id:input['authorityId'],operation_id:operation.id)}
 end

 def test_n3i_flag_off_keeps_fence_and_allows_only_existing_confirm_recovery
  input,operation=n3i_fixture
  result=n3i_prepare(input,operation)
  failed=false
  adapter=n3i_transport do |payload,_|
   if payload['phase']=='confirm'&&!failed
    failed=true;raise Timeout::Error
   end
  end
  service=n3i_service(transport:adapter)
  assert_raises(Timeout::Error){service.deliver!(request_id:result['request_id'])}
  service.instance_variable_set(:@environment,authority_environment.merge('TOYBACO_POSTING_RENEWAL_ENABLED'=>'false'))
  assert_raises(N3::PostingExecutionContext::Busy){@account.update!(status: :suspended)}
  assert_equal 'ready',service.deliver!(request_id:result['request_id'])['state']
  assert_equal 2,Toybaco::GrowthPostingAuthority.count
 end

 def test_n3i_independent_pg_account_lock_refuses_admission_without_waiting
  input,operation=n3i_fixture
  ready,release=Queue.new,Queue.new
  worker=Thread.new do
   Account.connection_pool.with_connection do
    Account.transaction do
     Account.lock.find(@account.id)
     ready << true
     release.pop
    end
   end
  rescue Exception => error
   ready << error
   raise
  end
  state=Timeout.timeout(5) {ready.pop}
  raise state if state.is_a?(Exception)
  assert_raises(N3::PostingExecutionContext::Busy){Timeout.timeout(3){n3i_prepare(input,operation)}}
  refute Toybaco::GrowthPostingRenewal.exists?
 ensure
  release << true if release
  raise 'independent Account lock did not finish' if worker&&!worker.join(5)
  worker&.value
 end

 def test_n3i_mismatched_remote_response_keeps_source_current_and_phase_fence
  input,operation=n3i_fixture
  result=n3i_prepare(input,operation)
  adapter=n3i_transport {|_,response| response['targetAuthorityHash']='e'*64}
  assert_raises(PreparationRecord::Invalid){n3i_service(transport:adapter).deliver!(request_id:result['request_id'])}
  assert_equal 'transferring',Toybaco::GrowthPostingRenewal.first.state
  assert_equal input['authorityId'],Toybaco::GrowthPostingAuthorityCurrent.first.authority_id
  assert_raises(N3::PostingExecutionContext::Busy){@account.update!(status: :suspended)}
 end

 def test_n3i_database_rejects_applied_phase_without_pointer_receipt
  input,operation=n3i_fixture
  n3i_prepare(input,operation)
  row=Toybaco::GrowthPostingRenewal.first
  assert_raises(ActiveRecord::StatementInvalid) do
   Toybaco::GrowthPostingRenewal.where(id:row.id).update_all(state:'applied',postiz_receipt:{},rails_pointer_hash:nil)
  end
  assert_equal 'prepared',row.reload.state
 end

 def n3i_due_inputs(input,operation)
  source=N3::PostingRenewalAuthority.source!(@account.id,input['authorityId'],now:n3_now,environment:authority_environment)
  failure=@account.with_lock {N3::OrdinaryRenewalFact.read!(operation.id,account:@account,now:n3_now)}
  [source.fetch('binding'),failure]
 end
 def n3i_due_reader(binding,client:n3i_client)
  N3::OrdinaryRenewalDueEvidence.new(binding:binding,previous_coverage:binding.fetch('coverage'),client:client,now:n3_now)
 end
 def test_n3i_due_boundary_is_nonexecuting_and_has_no_authority_or_expiry
  input,operation=n3i_fixture
  binding,failure=n3i_due_inputs(input,operation)
  n3_time(failure['due_at']-1)
  assert_raises(PreparationRecord::Invalid){n3i_due_reader(binding).verify!(failure:failure)}
  n3_time(failure['due_at'])
  proof=n3i_due_reader(binding).verify!(failure:failure)
  assert_equal ['ordinary_renewal_due',false,failure['due_at']],[proof['kind'],proof['execute'],proof['due_at']]
  refute proof.key?('authority_hash')
  refute proof.key?('expires_at')
  refute Toybaco::GrowthPostingRenewal.exists?
  assert_equal 1,Toybaco::GrowthPostingAuthority.count
 end
 def test_n3i_due_paid_invoice_or_mixed_invoice_cannot_request_stop_proof
  input,operation=n3i_fixture
  binding,failure=n3i_due_inputs(input,operation)
  n3_time(failure['due_at'])
  invoice=@n3_provider['latest_invoice']
  @n3_provider['latest_invoice']=invoice.merge('status'=>'paid','amount_remaining'=>0,'amount_paid'=>invoice['amount_due'])
  assert_raises(PreparationRecord::Invalid){n3i_due_reader(binding).verify!(failure:failure)}
  @n3_provider['latest_invoice']=invoice
  invoice['lines']['data'] << invoice['lines']['data'].first.deep_dup
  assert_raises(PreparationRecord::Invalid){n3i_due_reader(binding).verify!(failure:failure)}
 end
 def test_n3i_due_prior_coverage_and_signed_fact_shape_are_strict
  input,operation=n3i_fixture
  binding,failure=n3i_due_inputs(input,operation)
  n3_time(failure['due_at'])
  assert_raises(PreparationRecord::Invalid){N3::OrdinaryRenewalDueEvidence.new(binding:binding,previous_coverage:binding['coverage'].merge('term_end'=>0),client:n3i_client,now:n3_now)}
  assert_raises(PreparationRecord::Invalid){n3i_due_reader(binding).verify!(failure:failure.merge('due_at'=>failure['due_at']+1))}
  assert_raises(PreparationRecord::Invalid){n3i_due_reader(binding).verify!(failure:failure.merge('fact_hash'=>'invalid'))}
  @n3_previous_invoice['status_transitions']['paid_at']+=1
  assert_raises(PreparationRecord::Invalid){n3i_due_reader(binding).verify!(failure:failure)}
 end
 def test_n3i_due_outer_transaction_and_pending_change_are_rejected
  input,operation=n3i_fixture
  binding,failure=n3i_due_inputs(input,operation)
  n3_time(failure['due_at'])
  @account.with_lock {assert_raises(PreparationRecord::Invalid){n3i_due_reader(binding).verify!(failure:failure)}}
  @n3_provider['schedule']='sub_sched_change'
  assert_raises(PreparationRecord::Invalid){n3i_due_reader(binding).verify!(failure:failure)}
 end
 def test_n3i_due_reader_copies_binding_and_failure_before_provider_read
  input,operation=n3i_fixture
  binding,failure=n3i_due_inputs(input,operation)
  original=binding.deep_dup; original_failure=failure.deep_dup
  n3_time(failure['due_at'])
  client=n3i_client; original_retrieve=client.method(:retrieve_subscription)
  client.define_singleton_method(:retrieve_subscription) do |id|
   binding['contract']['stripe_price_id']='foreign'
   failure['invoice_id']='in_foreign'
   original_retrieve.call(id)
  end
  proof=n3i_due_reader(binding,client:client).verify!(failure:failure)
  assert_equal original.except('coverage'),proof['binding']
  assert_equal original_failure,proof['failure']
 end

end
