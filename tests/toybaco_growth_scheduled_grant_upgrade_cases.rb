# frozen_string_literal: true

module ToybacoScheduledGrantUpgradeRuntimeCases
  SG = Toybaco::Growth

  def teardown
    if @sg_used
      @sg_old_flag.nil? ? ENV.delete(SG::ScheduledGrantUpgrade::FLAG) : ENV[SG::ScheduledGrantUpgrade::FLAG] = @sg_old_flag
    end
    super
  end

  def sgu_fixture(used: 120, reservation: true)
    sd_fixture; sd_record
    sd_grant.update!(used: used)
    ledger = SG::AiLedger.new(@account, now: n3_now)
    @sg_reservation = ledger.reserve(request_key: '9' * 64, kind: 'post_draft', context_digest: '8' * 64) if reservation
    sd_paid
    sgu_setup
  end

  def sgu_setup
    @sg_used = true
    @sg_old_flag = ENV[SG::ScheduledGrantUpgrade::FLAG]
    ENV[SG::ScheduledGrantUpgrade::FLAG] = 'true'
    @sg_origin = sd_row.attributes.deep_dup
    @sg_old_grant = sd_grant.attributes.deep_dup
    @sg_source = @account.reload.internal_attributes.deep_dup
  end

  def sgu_rows = Toybaco::GrowthScheduledGrantUpgrade.where(account_id: @account.id).order(:id)
  def sgu_ledger = SG::AiLedger.new(@account, now: n3_now)

  def sgu_subscription(plan: 'standard', invoice_id: 'in_sgupgrade', paid_at: n3_now.to_i)
    coverage = @sg_source.fetch(SG::PaidPeriod::KEY)
    @n3_contract = Toybaco::Entitlements.snapshot_for(Toybaco::PlanCatalog.default.definition(plan, '2026-09-25.1'), cycle: @sd_cycle)
                                    .merge('stripe_price_id' => "price_#{plan}#{@sd_cycle}", 'subscription_item_id' => 'si_fixture')
    @n3_provider = n3_subscription(coverage['term_start'], coverage['term_end'], invoice_id, paid: true, paid_at: paid_at)
    @n3_provider['items']['data'][0]['price'] = sd_price(plan)
    @n3_provider['latest_invoice']['billing_reason'] = 'subscription_update'
    @n3_provider
  end

  def test_sg_paid_upgrade_preserves_original_and_reservations_once
    sgu_fixture
    assert_equal 0, sgu_ledger.summary['remaining']
    old_operation = Toybaco::GrowthAiOperation.find(@sg_reservation['operation_id']).attributes.deep_dup
    sgu_subscription
    assert_equal 'applied', sd_sync
    assert_equal 379, sgu_ledger.summary['remaining']
    assert_equal 500, sgu_ledger.summary['grants'].sum { |g| g['limit'] }
    assert_equal @sg_origin, sd_row.attributes
    assert_equal @sg_old_grant, sd_grant.attributes
    assert_equal old_operation, Toybaco::GrowthAiOperation.find(@sg_reservation['operation_id']).attributes
    assert_equal 1, sgu_rows.count
    before = sgu_rows.first.attributes.deep_dup
    ENV[SG::ScheduledGrantUpgrade::FLAG] = 'false'
    2.times { assert_equal 'applied', sd_sync }
    assert_equal before, sgu_rows.first.attributes
    assert_equal 379, sgu_ledger.summary['remaining']
    sgu_ledger.settle(operation_id: @sg_reservation['operation_id'], token: @sg_reservation['token'], outcome: 'released')
    assert_equal 380, sgu_ledger.summary['remaining']
  end

  def test_sg_mid_period_uses_remaining_seconds_and_keeps_consumed_history
    sgu_fixture(used: 20, reservation: false)
    period = SG::ScheduledDowngradeRecord.period(sd_row.receipt)
    n3_time(period['starts_at'] + (period['ends_at'] - period['starts_at']) / 2)
    sgu_subscription
    assert_equal 'applied', sd_sync
    assert_equal 200, sgu_rows.first.receipt['additional_units']
    assert_equal 280, sgu_ledger.summary['remaining']
    assert_equal @sg_old_grant, sd_grant.attributes
  end

  def test_sg_unpaid_changed_nonce_customer_mode_and_period_cannot_authorize
    sgu_fixture
    original = sgu_subscription.deep_dup
    @n3_provider['latest_invoice']['status'] = 'open'
    @n3_provider['latest_invoice']['amount_remaining'] = @n3_provider['latest_invoice']['amount_due']
    @n3_provider['latest_invoice']['amount_paid'] = 0
    assert_equal 'payment_pending', sd_sync
    refute sgu_rows.exists?
    [->(s) { s['metadata']['toybaco_purchase_nonce'] = 'different' },
     ->(s) { s['customer'] = 'cus_foreign' }, ->(s) { s['livemode'] = true },
     ->(s) { s['latest_invoice']['amount_paid'] -= 1 },
     ->(s) { s['billing_cycle_anchor'] += 1 }].each do |change|
      @n3_provider = original.deep_dup; change.call(@n3_provider)
      assert_raises(SG::PostingPreparationRecord::Invalid) { sd_sync }
      refute sgu_rows.exists?
      assert_equal 'light', Toybaco::Entitlements.contract_for(@account.reload)['plan_id']
    end
    @n3_provider = original.deep_dup
    @n3_provider['items']['data'][0]['current_period_end'] += 60
    assert_equal 'payment_pending', sd_sync
    refute sgu_rows.exists?
  end

  def test_sg_same_period_upgrade_requires_flag_and_original_recovery
    sgu_fixture; sgu_subscription
    ENV[SG::ScheduledGrantUpgrade::FLAG] = 'false'
    assert_raises(SG::PostingPreparationRecord::Invalid) { sd_sync }
    refute sgu_rows.exists?
    ENV[SG::ScheduledGrantUpgrade::FLAG] = 'true'
    purchase = @account.internal_attributes.fetch(SG::PurchaseIntent::KEY).merge('nonce' => 'other')
    n3_mutate(SG::PurchaseIntent::KEY => purchase)
    assert_raises(SG::PostingPreparationRecord::Invalid) { sd_sync }
    refute sgu_rows.exists?
  end

  def test_sg_old_light_replay_cannot_rewind_current_standard_or_grants
    sgu_fixture
    old = @n3_provider.deep_dup
    sgu_subscription; sd_sync
    receipt = sgu_rows.first.attributes.deep_dup
    @n3_provider = old
    assert_raises(SG::PostingPreparationRecord::Invalid) { sd_sync }
    assert_equal 'standard', Toybaco::Entitlements.contract_for(@account.reload)['plan_id']
    assert_equal receipt, sgu_rows.first.attributes
    assert_equal 379, sgu_ledger.summary['remaining']
  end

  def test_sg_late_failure_rolls_back_child_marker_contract_and_all_grants
    sgu_fixture; sgu_subscription
    marker = Account.connection.select_value("SELECT count(*) FROM toybaco_durable_capability_acceptances WHERE capability='scheduled-grant-upgrade-v1'")
    account_before = @account.reload.attributes.deep_dup
    grants_before = Toybaco::GrowthAiGrant.where(account_id: @account.id).order(:id).map(&:attributes)
    SG::TrialLifecycle.stub(:new, ->(*) { raise IOError, 'after verified grant writes' }) do
      assert_raises(IOError) { sd_sync }
    end
    assert_equal account_before, @account.reload.attributes
    assert_equal grants_before, Toybaco::GrowthAiGrant.where(account_id: @account.id).order(:id).map(&:attributes)
    refute sgu_rows.exists?
    assert_equal marker, Account.connection.select_value("SELECT count(*) FROM toybaco_durable_capability_acceptances WHERE capability='scheduled-grant-upgrade-v1'")
    assert_equal 'applied', sd_sync
  end

  def test_sg_missing_expected_additional_grant_rolls_back_everything
    sgu_fixture; sgu_subscription
    creator = SG::AiGrants.instance_method(:issue!)
    SG::AiGrants.define_method(:issue!) do |**args|
      args[:source_key].include?(':upgrade:') ? nil : creator.bind_call(self, **args)
    end
    assert_raises(SG::PostingPreparationRecord::Invalid) { sd_sync }
    refute sgu_rows.exists?
    assert_equal 'light', Toybaco::Entitlements.contract_for(@account.reload)['plan_id']
  ensure
    SG::AiGrants.define_method(:issue!, creator) if creator
  end

  def test_sg_missing_mutable_failure_key_does_not_bypass_durable_source_check
    sgu_fixture
    n3_mutate(SG::RenewalGrace::FAILURE_KEY => nil)
    sgu_subscription
    assert_equal 'applied', sd_sync
    assert_equal 379, sgu_ledger.summary['remaining']
    refute_nil sgu_rows.first
  end

  def test_sg_contract_attribute_overwrite_is_not_paid_upgrade_evidence
    sgu_fixture; sgu_subscription
    target = Toybaco::SubscriptionSync.new(client: nil).resolve(@n3_provider, previous: @sg_source['toybaco_contract'])
    coverage = SG::PaidCoverage.new(@n3_provider, target).verified
    n3_mutate('toybaco_contract' => target, SG::PaidPeriod::KEY => coverage, SG::RenewalGrace::FAILURE_KEY => nil)
    assert_raises(SG::PostingPreparationRecord::Invalid) { sd_sync }
    refute sgu_rows.exists?
  end

  def test_sg_second_leg_uses_immutable_parent_and_old_response_cannot_rewind
    sgu_fixture; sgu_subscription; sd_sync
    first = sgu_rows.first.attributes.deep_dup
    standard = @n3_provider.deep_dup
    n3_time(n3_now.to_i + 1)
    sgu_subscription(plan: 'pro', invoice_id: 'in_sgpro')
    assert_equal 'applied', sd_sync
    assert_equal 2, sgu_rows.count
    assert_equal first['receipt_hash'], sgu_rows.last.parent_hash
    assert_equal first, sgu_rows.first.attributes
    assert_equal 1877, sgu_ledger.summary['remaining']
    @n3_provider = standard
    assert_raises(SG::PostingPreparationRecord::Invalid) { sd_sync }
  end

  def test_sg_receipt_with_future_or_foreign_period_even_matching_hash_is_denied
    sgu_fixture; sgu_subscription; sd_sync
    row = sgu_rows.first; original = row.receipt.deep_dup
    [->(r) { r['created_at'] += 60 }, ->(r) { r['period']['ends_at'] += 1 },
     ->(r) { r['target_binding']['purchase_nonce'] = 'foreign' },
     ->(r) { r['target_binding']['coverage']['invoice_id'] = r['source_binding']['coverage']['invoice_id'] }].each do |change|
      value = original.deep_dup; change.call(value)
      Account.connection.execute("UPDATE toybaco_growth_scheduled_grant_upgrades SET receipt=#{Account.connection.quote(JSON.generate(value))}::jsonb, receipt_hash=#{Account.connection.quote(SG::PostingPreparationRecord.digest(value))} WHERE id=#{row.id}")
      assert_raises(SG::PostingPreparationRecord::Invalid) { sgu_ledger.summary }
    end
  end

  def test_sg_acceptance_survives_account_and_business_receipt_delete
    sgu_fixture; sgu_subscription; sd_sync
    child = sgu_rows.first
    sd_without_account_row do
      assert child.reload
      child.delete
      assert_equal 1, Account.connection.select_value("SELECT count(*) FROM toybaco_durable_capability_acceptances WHERE capability='scheduled-grant-upgrade-v1'")
    end
  end
  def test_sg_concurrent_subscription_receipts_create_one_child_and_one_additional_grant
    sgu_fixture; sgu_subscription
    snapshot = @n3_provider.deep_dup
    ids = [@account.id, @n3_subscription_id]
    ready = Queue.new; start = Queue.new
    workers = 2.times.map do
      Thread.new do
        Account.connection_pool.with_connection do
          client = Object.new
          client.define_singleton_method(:retrieve_subscription) { |_| snapshot.deep_dup }
          ready << true; start.pop
          Toybaco::SubscriptionSync.new(client: client).call(Account.find(ids[0]), subscription_id: ids[1])
        end
      end
    end
    2.times { ready.pop }; 2.times { start << true }
    workers.each { |thread| assert thread.join(5); assert_equal 'applied', thread.value }
    assert_equal 1, sgu_rows.count
    assert_equal 379, sgu_ledger.summary['remaining']
  ensure
    workers&.each { |thread| thread.kill.join if thread.alive? }
  end

  def test_sg_no_transaction_and_old_snapshot_cannot_admit_a_child
    sgu_fixture; sgu_subscription
    target = Toybaco::SubscriptionSync.new(client: nil).resolve(@n3_provider, previous: @sg_source['toybaco_contract'])
    assert_raises(SG::PostingPreparationRecord::Invalid) do
      SG::ScheduledGrantUpgrade.new(@account, now: n3_now).prepare!(sd_row, @n3_provider, target)
    end
    Account.transaction(isolation: :repeatable_read) do
      assert_raises(SG::PostingPreparationRecord::Invalid) { sd_sync }
    end
    refute sgu_rows.exists?
    assert_equal 'light', Toybaco::Entitlements.contract_for(@account.reload)['plan_id']
  end

end
