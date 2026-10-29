# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/mock'
require 'active_support/testing/time_helpers'
require Rails.root.join('lib/toybaco/growth/billing_receipt')
require Rails.root.join('lib/toybaco/growth/billing_execution')
require Rails.root.join('app/jobs/toybaco/growth_payment_sweep_job')
require Rails.root.join('lib/toybaco/subscription_reconciliation/execution')

class ToybacoBillingIngressRuntimeTest < Minitest::Test
  include ActiveSupport::Testing::TimeHelpers
  Growth = Toybaco::Growth
  NOW = Time.utc(2026, 9, 24, 8)

  def setup
    @previous = ENV.to_h.slice('TOYBACO_STRIPE_MODE', 'TOYBACO_BILLING_INGRESS_ENABLED')
    ENV.update('TOYBACO_STRIPE_MODE' => 'test', 'TOYBACO_BILLING_INGRESS_ENABLED' => 'true')
    @adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @events, @requests, @subscriptions, @accounts = [], [], [], []
    travel_to NOW
  end

  def teardown
    operations = Toybaco::RenewalOperation.where(subscription_id: @subscriptions)
    operations.update_all(first_fact_id: nil, first_failed_at: nil, due_at: nil, state: 'unverified')
    Toybaco::RenewalInvoiceFact.where(subscription_id: @subscriptions).delete_all
    operations.delete_all
    Toybaco::BillingEvent.where(id: @events).or(Toybaco::BillingEvent.where(reference_id: @subscriptions)).delete_all
    Toybaco::SubscriptionSyncRequest.where(id: @requests).or(Toybaco::SubscriptionSyncRequest.where(subscription_id: @subscriptions)).delete_all
    Account.where(id: @accounts).destroy_all
    %w[TOYBACO_STRIPE_MODE TOYBACO_BILLING_INGRESS_ENABLED].each { |key| @previous.key?(key) ? ENV[key] = @previous[key] : ENV.delete(key) }
    ActiveJob::Base.queue_adapter = @adapter
    travel_back
  end

  def event(type: 'customer.subscription.updated', reference: "sub_#{SecureRandom.hex(8)}", id: "evt_#{SecureRandom.hex(8)}")
    object = { 'id' => reference, 'object' => 'subscription', 'status' => 'stale', 'private' => 'never retain' }
    if type == 'checkout.session.completed'
      object = { 'id' => reference, 'object' => 'checkout.session', 'mode' => 'subscription',
                 'metadata' => { 'toybaco_existing_account_id' => '123', 'toybaco_purchase_nonce' => 'never retain' },
                 'customer_details' => { 'email' => 'never-retain@example.invalid' }, 'payment_status' => 'unpaid' }
    end
    { 'id' => id, 'object' => 'event', 'type' => type, 'livemode' => false, 'created' => NOW.to_i, 'data' => { 'object' => object } }
  end

  def accept(value = event)
    attrs = Growth::BillingSnapshot.new(value).read
    row = Growth::BillingReceipt.accept!(attrs)
    @events << row.id
    row
  end

  def accept_subscription(row)
    request = Growth::BillingSubscription.accept!(row)
    @requests << request.id
    request
  end

  # 更新請求(subscription_cycle)の invoice の通知。購読 ID は teardown で消す名簿に載せる。
  def renewal_event(subscription: "sub_#{SecureRandom.hex(8)}", type: 'invoice.paid')
    @subscriptions << subscription
    object = { 'object' => 'invoice', 'id' => "in_#{SecureRandom.hex(8)}", 'customer' => "cus_#{SecureRandom.hex(8)}",
               'parent' => { 'subscription_details' => { 'subscription' => subscription } }, 'billing_reason' => 'subscription_cycle',
               'attempt_count' => 1, 'customer_email' => 'never-retain@example.invalid' }
    { 'id' => "evt_#{SecureRandom.hex(8)}", 'object' => 'event', 'type' => type, 'livemode' => false, 'created' => NOW.to_i - 60,
      'data' => { 'object' => object } }
  end

  def store!(subscription)
    account = Account.create!(name: 'Billing ingress fixture', locale: 'ja', internal_attributes: { 'toybaco_subscription_id' => subscription })
    @accounts << account.id
    account
  end

  def logged
    io = StringIO.new
    value = Rails.stub(:logger, ActiveSupport::Logger.new(io)) { yield }
    [value, io.string]
  end

  def execute_sync(request, at:)
    Toybaco::SubscriptionReconciliation::Execution.new(request, now: at, environment: { 'TOYBACO_STRIPE_MODE' => 'test' }).call
  end

  def provider
    client = Object.new
    client.define_singleton_method(:retrieve_subscription) { |id| { 'id' => id, 'object' => 'subscription', 'livemode' => false } }
    client
  end

  def run_attention_task(name, id, reason)
    require 'rake'
    Rails.application.load_tasks unless Rake::Task.task_defined?("toybaco:#{name}")
    output, = capture_io { Rake::Task["toybaco:#{name}"].execute(Rake::TaskArguments.new(%i[id reason], [id.to_s, reason])) }
    output
  end

  # 店舗に結び付かない購読(Stripe を共用する他製品)の更新請求も、受付は従来どおり記録し(署名した事実・照合の要求。ACK の形も同じ)、
  # 処理は店舗を待って再試行し、期限で確認待ちになる(手元の記録だけでは他製品と決められず、開通の途中の正規の購読と区別できない)。
  # 運営が他製品と確かめた確認待ちは、理由 foreign で閉じる。
  def test_another_products_renewal_waits_into_attention_until_an_operator_closes_it_as_foreign
    row = accept(renewal_event)
    subscription = @subscriptions.last
    assert Toybaco::RenewalInvoiceFact.exists?(billing_event_id: row.id)
    Growth::BillingExecution.new(row, client: provider).call
    assert_equal %w[pending provider_or_processing_unavailable], row.reload.values_at(:state, :result)
    travel_to NOW + 86_401
    _, log = logged { Growth::BillingExecution.new(row, client: provider).call }
    assert_equal %w[attention retry_limit], row.reload.values_at(:state, :result)
    assert_equal ["TOYBACO_BILLING_ATTENTION_NEW receipt=#{row.id} result=retry_limit"], log.scan(/TOYBACO_BILLING_ATTENTION_NEW .*$/)
    assert_includes run_attention_task('billing_attention_close', row.id, 'foreign'),
                    "TOYBACO_ATTENTION_OPS kind=billing-event id=#{row.id} action=close reason=foreign state=completed"
    assert_equal %w[completed operator_closed], row.reload.values_at(:state, :result)
    assert_equal 'foreign', row.recovery_log.last['reason']
    assert_nil Toybaco::RenewalOperation.find_by!(subscription_id: subscription).account_id
  end

  # 店舗の作成を待ち切った照合の要求も、従来どおり確認待ちになる(1 回だけ TOYBACO_SUBSCRIPTION_SYNC_ATTENTION_NEW)。
  # 運営が他製品と確かめたら理由 foreign で閉じ、次の通知は終わった要求と同じく再開する。
  def test_a_sync_request_that_waits_out_provisioning_turns_attention_and_is_closed_as_foreign
    row = accept
    Growth::BillingExecution.new(row).call
    request = Toybaco::SubscriptionSyncRequest.find(row.reload.subscription_sync_request_id)
    @requests << request.id
    assert_equal 'pending', execute_sync(request, at: NOW)
    assert_equal ['pending', 'not_provisioned', 1], request.reload.values_at(:state, :result, :attempts)
    request.update!(attempts: Toybaco::SubscriptionReconciliation::ATTEMPTS - 1, next_attempt_at: NOW)
    state, log = logged { execute_sync(request, at: NOW + 60) }
    assert_equal ['attention', 'attention', 'not_provisioned'], [state, *request.reload.values_at(:state, :result)]
    assert_equal ["TOYBACO_SUBSCRIPTION_SYNC_ATTENTION_NEW id=#{request.id} result=not_provisioned"],
                 log.scan(/TOYBACO_SUBSCRIPTION_SYNC_ATTENTION\S* .*$/)
    assert_includes run_attention_task('sync_attention_close', request.id, 'foreign'),
                    "TOYBACO_ATTENTION_OPS kind=sync-request id=#{request.id} action=close reason=foreign state=completed"
    assert_equal ['completed', 'operator_closed', 0], request.reload.values_at(:state, :result, :completed_revision)
    again = accept_subscription(accept(event(reference: row.reference_id)))
    assert_equal [request.id, 'pending', 0, 2], again.values_at(:id, :state, :attempts, :requested_revision)
  end

  # 受付が確認待ちになった時だけ TOYBACO_BILLING_ATTENTION_NEW が 1 回出る(billing-attention の alarm が数える行)。毎分の sweep が
  # 確認待ちの残る間ずっと出す pending_receipts=true の行には含まれない。
  def test_a_new_billing_attention_logs_its_marker_once_and_the_sweep_repeat_does_not
    row = accept
    row.update!(state: 'processing', attempts: 47, lease_token: 'fixture', lease_expires_at: NOW - 1)
    travel_to NOW + 86_400
    _, log = logged { Growth::BillingExecution.new(row).call }
    assert_equal %w[attention retry_limit], row.reload.values_at(:state, :result)
    assert_equal ["TOYBACO_BILLING_ATTENTION_NEW receipt=#{row.id} result=retry_limit"], log.scan(/TOYBACO_BILLING_ATTENTION_NEW .*$/)
    _, log = logged { 2.times { Growth::BillingExecution.new(row).call } }
    refute_includes log, 'TOYBACO_BILLING_ATTENTION_NEW'
    _, log = logged { Growth::BillingReceipt.sweep(now: Time.now.utc) }
    assert_includes log, 'TOYBACO_BILLING_ATTENTION pending_receipts=true'
    refute_includes log, 'TOYBACO_BILLING_ATTENTION_NEW'
    corrupt = accept
    Toybaco::BillingEvent.connection.execute("UPDATE toybaco_billing_events SET payload_digest = '#{'0' * 64}' WHERE id = #{corrupt.id}")
    _, log = logged { Growth::BillingExecution.new(corrupt.reload).call }
    assert_equal ["TOYBACO_BILLING_ATTENTION_NEW receipt=#{corrupt.id} result=payment_mismatch"], log.scan(/TOYBACO_BILLING_ATTENTION_NEW .*$/)
  end

  # attention を commit した直後(TOYBACO_BILLING_ATTENTION_NEW と運営メールの前)に worker が止まっても、新規確認待ちの行は
  # commit の前に出ている(行は再び claim されず、毎分の sweep の行は alarm に当たらないため、ここで出ていないと気付けない)。
  class StopAfterCommit < StandardError; end

  def test_the_new_billing_attention_line_is_logged_before_the_commit_a_crash_after_it_cannot_lose
    row = accept
    Toybaco::BillingEvent.connection.execute("UPDATE toybaco_billing_events SET payload_digest = '#{'0' * 64}' WHERE id = #{row.id}")
    execution = Growth::BillingExecution.new(row.reload)
    execution.singleton_class.prepend(Module.new { def finish!(state, result) = super.tap { raise StopAfterCommit if state == 'attention' } })
    _, log = logged { assert_raises(StopAfterCommit) { execution.call } }
    assert_equal %w[attention payment_mismatch], Toybaco::BillingEvent.find(row.id).values_at(:state, :result)
    assert_equal ["TOYBACO_BILLING_ATTENTION_NEW receipt=#{row.id} result=payment_mismatch"], log.scan(/TOYBACO_BILLING_ATTENTION_NEW .*$/)
    _, log = logged { Growth::BillingExecution.new(Toybaco::BillingEvent.find(row.id)).call }
    refute_includes log, 'TOYBACO_BILLING_ATTENTION_NEW'
  end

  def test_each_new_sync_attention_logs_its_marker_once_and_the_sweep_repeat_is_a_different_line
    row = accept
    subscription = row.reference_id
    request = accept_subscription(row)
    @subscriptions << subscription
    request.update!(attempts: Toybaco::SubscriptionReconciliation::ATTEMPTS - 1, next_attempt_at: NOW)
    state, log = logged { execute_sync(request, at: NOW + 60) }
    assert_equal ['attention', 'attention', 'not_provisioned'], [state, *request.reload.values_at(:state, :result)]
    assert_equal ["TOYBACO_SUBSCRIPTION_SYNC_ATTENTION_NEW id=#{request.id} result=not_provisioned"],
                 log.scan(/TOYBACO_SUBSCRIPTION_SYNC_ATTENTION\S* .*$/)
    _, log = logged { 2.times { execute_sync(request, at: NOW + 120) } }
    refute_includes log, 'TOYBACO_SUBSCRIPTION_SYNC_ATTENTION_NEW'
    _, log = logged { Toybaco::SubscriptionReconciliationSweepJob.perform_now }
    assert_includes log.lines, "TOYBACO_SUBSCRIPTION_SYNC_ATTENTION\n"
    refute_includes log, 'TOYBACO_SUBSCRIPTION_SYNC_ATTENTION_NEW'
    # 期限(claim! の期限判定)と、照合の失敗(finish! の attention)でも 1 回ずつ。
    other = accept_subscription(accept)
    other.update!(next_attempt_at: NOW, deadline_at: NOW)
    _, log = logged { execute_sync(other, at: NOW + 1) }
    assert_equal ["TOYBACO_SUBSCRIPTION_SYNC_ATTENTION_NEW id=#{other.id} result=renewal_pending"], log.scan(/TOYBACO_SUBSCRIPTION_SYNC_ATTENTION_NEW .*$/)
    split = accept_subscription(accept)
    2.times { store!(split.subscription_id) }
    @subscriptions << split.subscription_id
    state, log = logged { execute_sync(split, at: NOW) }
    assert_equal ['attention', 'binding_unresolved'], [state, split.reload.result]
    assert_equal ["TOYBACO_SUBSCRIPTION_SYNC_ATTENTION_NEW id=#{split.id} result=binding_unresolved"], log.scan(/TOYBACO_SUBSCRIPTION_SYNC_ATTENTION_NEW .*$/)
  end

  # 運営が始め直した後、照合の job が走る前に購読の店舗が移っても(運営の例外的な修正だけで起きる)、要求を superseded で黙って
  # 終わらせない。Stripe を読まず(client なし)、どの店舗にも書かずに確認待ち(account_moved)にし、新規確認待ちの行を 1 回出す。
  # fixed では始め直せず(account-moved)、rebind で要求の店舗を外す。
  def test_a_store_move_after_the_retry_and_before_the_job_turns_attention_instead_of_superseded
    row = accept
    subscription = row.reference_id
    @subscriptions << subscription
    store_a = store!(subscription)
    request = accept_subscription(row)
    assert_equal store_a.id, request.account_id
    request.update!(state: 'attention', result: 'retry_limit', attempts: Toybaco::SubscriptionReconciliation::ATTEMPTS)
    assert_includes run_attention_task('sync_attention_retry', request.id, 'fixed'), "previous_account=#{store_a.id} owner=#{store_a.id} revision=2"
    store_a.update!(internal_attributes: {})
    store_b = store!(subscription)
    before = store_b.reload.attributes
    state, log = logged { execute_sync(request, at: NOW) }
    assert_equal ['attention', 'attention', 'account_moved', store_a.id], [state, *request.reload.values_at(:state, :result, :account_id)]
    assert_equal ["TOYBACO_SUBSCRIPTION_SYNC_ATTENTION_NEW id=#{request.id} result=account_moved"], log.scan(/TOYBACO_SUBSCRIPTION_SYNC_ATTENTION_NEW .*$/)
    assert_equal before, store_b.reload.attributes
    refused = assert_raises(SystemExit) { run_attention_task('sync_attention_retry', request.id, 'fixed') }
    assert_includes refused.message, "id=#{request.id} result=refused reason=account-moved"
    assert_includes run_attention_task('sync_attention_retry', request.id, 'rebind'),
                    "previous_result=account-moved previous_account=#{store_a.id} owner=#{store_b.id}"
    assert_equal ['pending', nil], request.reload.values_at(:state, :account_id)
  end

  # 後の通知(refresh_request!)も要求の店舗を変えない。終わった要求に次の通知が届き、照合が走る時に店舗が移っていれば確認待ち
  # (account_moved)にし、その後の通知でも再開しない。どの店舗もその購読を持たない要求(店舗が新しい購読に替わった)だけが、
  # 従来どおり superseded で終わる。
  def test_a_later_notice_for_a_moved_subscription_turns_attention_and_only_an_unheld_one_is_superseded
    row = accept
    subscription = row.reference_id
    @subscriptions << subscription
    store_a = store!(subscription)
    request = accept_subscription(row)
    request.update!(state: 'completed', result: 'applied', completed_revision: 1, completed_at: NOW)
    store_a.update!(internal_attributes: {})
    store!(subscription)
    again = accept_subscription(accept(event(reference: subscription)))
    assert_equal [request.id, 'pending', 2, store_a.id], again.values_at(:id, :state, :requested_revision, :account_id)
    state, log = logged { execute_sync(again, at: NOW) }
    assert_equal ['attention', 'attention', 'account_moved', store_a.id], [state, *again.reload.values_at(:state, :result, :account_id)]
    assert_equal ["TOYBACO_SUBSCRIPTION_SYNC_ATTENTION_NEW id=#{request.id} result=account_moved"], log.scan(/TOYBACO_SUBSCRIPTION_SYNC_ATTENTION_NEW .*$/)
    last = accept_subscription(accept(event(reference: subscription)))
    assert_equal ['attention', 'account_moved', 2, store_a.id], last.values_at(:state, :result, :requested_revision, :account_id)
    unheld = accept
    @subscriptions << unheld.reference_id
    store_c = store!(unheld.reference_id)
    other = accept_subscription(unheld)
    store_c.update!(internal_attributes: { 'toybaco_subscription_id' => "sub_#{SecureRandom.hex(8)}" })
    state, log = logged { execute_sync(other, at: NOW) }
    assert_equal ['superseded', 'superseded', 'superseded'], [state, *other.reload.values_at(:state, :result)]
    refute_includes log, 'TOYBACO_SUBSCRIPTION_SYNC_ATTENTION_NEW'
  end

  # 照合が要求の店舗 A を最初に読んだ時には購読が外れていても(古い読み)、今の持ち主を数える前に運営の修復が同じ A へ購読を戻して
  # いれば、確認待ち(account_moved)にせず、A を読み直して照合を続ける(Stripe を読む)。今の持ち主は 1 つの query の結果で決める。
  def test_a_repair_back_to_the_bound_store_between_the_two_reads_keeps_reconciling_instead_of_account_moved
    row = accept
    subscription = row.reference_id
    @subscriptions << subscription
    store_a = store!(subscription)
    request = accept_subscription(row)
    assert_equal store_a.id, request.account_id
    stale = Account.find(store_a.id)
    stale.internal_attributes = {}
    original = Account.method(:find_by)
    reads = []
    find_by = lambda do |*args, **options|
      reads << (options.empty? ? args.first : options)
      reads.size == 1 ? stale : original.call(*args, **options)
    end
    # 直しの前(f3a45d7e)の判定(古い読みが外れた後の exists?)を同じ状態に当てると account_moved になる。手元に Rails が無いので、
    # この試験が直しの前の実装で落ちることを、同じ CI の 1 回の run で示す。
    refute_equal subscription, stale.internal_attributes&.fetch('toybaco_subscription_id', nil)
    assert_equal :account_moved, (Toybaco::SubscriptionReconciliation.accounts_for(subscription).exists? ? :account_moved : :superseded)
    assert_equal [store_a.id], Toybaco::SubscriptionReconciliation.accounts_for(subscription).limit(2).pluck(:id)
    # 照合が続いたことは Stripe の読み(retrieve)で見て、そこで止める(止めた run は processing_unavailable で再試行を待つ)。
    retrieved = []
    client = Object.new
    client.define_singleton_method(:retrieve_subscription) { |id| retrieved << id; raise IOError, 'fixture provider read' }
    execution = Toybaco::SubscriptionReconciliation::Execution.new(request, client: client, now: NOW,
                                                                            environment: { 'TOYBACO_STRIPE_MODE' => 'test' })
    state, log = logged { Account.stub(:find_by, find_by) { execution.call } }
    assert_equal({ id: store_a.id }, reads.first)
    assert_equal [subscription], retrieved
    assert_equal ['pending', 'pending', 'processing_unavailable', store_a.id], [state, *request.reload.values_at(:state, :result, :account_id)]
    refute_includes log, 'TOYBACO_SUBSCRIPTION_SYNC_ATTENTION_NEW'
    assert_equal subscription, store_a.reload.internal_attributes['toybaco_subscription_id']
  end

  # lease を失った fail!(その間に他の worker が claim し直して確認待ちにした)は、旧形式の行も運営メール(tell_operations)も出さない。
  # その確認待ちを書いた worker が知らせる。lease を保った fail! は、従来どおり新旧の行と運営メールを 1 回ずつ出す。
  def test_a_fail_that_lost_its_lease_logs_no_attention_line_and_sends_no_operations_mail
    mails = []
    counting = Module.new { define_method(:tell_operations) { |result| mails << result } }
    stolen = Module.new do
      def reconcile
        Toybaco::BillingEvent.where(id: @event.id).update_all(state: 'attention', result: 'payment_mismatch', lease_token: nil, lease_expires_at: nil)
        super
      end
    end
    lost, kept = Array.new(2) do
      row = accept
      Toybaco::BillingEvent.connection.execute("UPDATE toybaco_billing_events SET payload_digest = '#{'0' * 64}' WHERE id = #{row.id}")
      row.reload
    end
    execution = Growth::BillingExecution.new(lost)
    execution.singleton_class.prepend(counting, stolen)
    _, log = logged { execution.call }
    assert_equal %w[attention payment_mismatch], lost.reload.values_at(:state, :result)
    assert_empty mails
    refute_includes log, 'TOYBACO_BILLING_ATTENTION'
    execution = Growth::BillingExecution.new(kept)
    execution.singleton_class.prepend(counting)
    _, log = logged { execution.call }
    assert_equal %w[attention payment_mismatch], kept.reload.values_at(:state, :result)
    assert_equal ['payment_mismatch'], mails
    assert_equal ["TOYBACO_BILLING_ATTENTION_NEW receipt=#{kept.id} result=payment_mismatch", "TOYBACO_BILLING_ATTENTION receipt=#{kept.id}"],
                 log.scan(/TOYBACO_BILLING_ATTENTION\S* receipt=.*$/)
  end

  def test_minimal_committed_receipt_is_idempotent_and_does_not_extend_deadline
    value = event
    row = accept(value)
    travel_to NOW + 3600
    again = accept(value)
    assert_equal row.id, again.id
    assert_equal [NOW + 86_400, 0], [again.deadline_at, again.attempts]
    assert_equal({ 'subscription' => value.dig('data', 'object', 'id') }, again.snapshot.dig('data', 'object'))
    refute_includes again.snapshot.to_json, 'never retain'
  end

  def test_event_conflict_wrong_mode_future_and_duplicate_json_fail_closed
    row = accept
    conflict = event(reference: row.reference_id, id: row.event_id)
    conflict['type'] = 'customer.subscription.deleted'
    assert_raises(Growth::BillingReceipt::Conflict) { accept(conflict) }
    [event.merge('livemode' => true), event.merge('created' => NOW.to_i + 1), event.merge('account' => 'acct_other')].each do |value|
      assert_raises(Growth::PaymentSignature::Invalid) { Growth::BillingSnapshot.new(value).read }
    end
    raw = '{"id":"evt_one","id":"evt_two"}'
    secret = 'whsec_fixture12345678901234567890'
    signature = "t=#{NOW.to_i},v1=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "#{NOW.to_i}.#{raw}")}"
    assert_raises(Growth::PaymentSignature::Invalid) do
      Growth::PaymentSignature.verify!(raw, signature, environment: { 'TOYBACO_STRIPE_PACK_WEBHOOK_SECRET' => secret })
    end
  end

  def test_invoice_can_also_have_an_independent_existing_payment_receipt
    value = event(type: 'invoice.payment_failed')
    value['data']['object'] = { 'object' => 'invoice', 'subscription' => 'sub_invoice', 'id' => 'in_invoice' }
    row = accept(value)
    payment = Toybaco::GrowthPaymentEvent.create!(event_id: row.event_id, action: 'renewal_failure', reference_id: 'in_invoice',
      snapshot: { 'fixture' => true }, payload_digest: 'a' * 64, next_attempt_at: NOW)
    assert_equal 'subscription_notice', row.action
    assert_equal row.event_id, payment.event_id
  ensure
    payment&.destroy!
  end

  def test_receipt_and_subscription_admission_reject_outer_transaction
    row = accept
    Account.transaction do
      assert_raises(Growth::BillingReceipt::Conflict) { accept }
      assert_raises(Toybaco::SubscriptionReconciliation::Invalid) { accept_subscription(row) }
      assert_raises(Toybaco::SubscriptionReconciliation::Invalid) { Growth::BillingExecution.new(row).call }
    end
  end

  def test_ack_loss_after_revision_commit_reuses_mapping_without_refresh_or_budget_reset
    row = accept
    request = accept_subscription(row)
    assert_equal [request.id, 1], [row.reload.subscription_sync_request_id, row.requested_revision]
    deadline = request.deadline_at
    request.update!(state: 'completed', completed_revision: 1, completed_at: NOW, attempts: 7)
    travel_to NOW + 7200
    again = accept_subscription(row)
    assert_equal [request.id, 1, 7, deadline, 'completed'],
      [again.id, again.requested_revision, again.attempts, again.deadline_at, again.state]
  end

  def test_failure_after_revision_update_before_event_mapping_rolls_back_both
    first = accept
    request = accept_subscription(first)
    second = accept(event(reference: first.reference_id))
    second.stub(:update!, ->(*) { raise IOError, 'fixture mapping write failure' }) do
      assert_raises(IOError) { accept_subscription(second) }
    end
    assert_equal 1, request.reload.requested_revision
    assert_nil second.reload.subscription_sync_request_id
    assert_equal 2, accept_subscription(second).requested_revision
  end

  def test_failure_after_new_request_insert_does_not_leave_an_unmapped_request
    row = accept
    row.stub(:update!, ->(*) { raise IOError, 'fixture mapping write failure' }) do
      assert_raises(IOError) { accept_subscription(row) }
    end
    refute Toybaco::SubscriptionSyncRequest.exists?(subscription_id: row.reference_id)
    assert_equal 1, accept_subscription(row).requested_revision
  end

  def test_distinct_event_during_running_creates_next_revision_but_does_not_extend_retry_budget
    row = accept
    request = accept_subscription(row)
    request.update!(state: 'running', attempts: 47)
    other = accept(event(reference: row.reference_id))
    travel_to NOW + 86_000
    next_request = accept_subscription(other)
    assert_equal [2, 47, NOW + 86_400], [next_request.requested_revision, next_request.attempts, next_request.deadline_at]
    request.update!(state: 'attention', result: 'retry_limit')
    last = accept(event(reference: row.reference_id))
    assert_equal [2, 'attention'], [accept_subscription(last).requested_revision, request.reload.state]
  end

  def test_queue_ack_loss_and_flag_off_are_recovered_without_a_new_cron
    row = accept
    jobs = []
    Toybaco::BillingEventJob.stub(:perform_later, ->(id) { jobs << id; raise ActiveJob::EnqueueError }) do
      Growth::BillingReceipt.enqueue(row)
    end
    assert_equal [row.id], jobs
    assert_equal 'pending', row.reload.state
    ENV['TOYBACO_BILLING_INGRESS_ENABLED'] = 'false'
    travel_to NOW + 61
    Toybaco::GrowthPaymentSweepJob.perform_now
    queued = ActiveJob::Base.queue_adapter.enqueued_jobs.select { |entry| entry[:job] == Toybaco::BillingEventJob }
    assert_equal [row.id], queued.flat_map { |entry| entry[:args] }
  end

  def test_subscription_worker_uses_durable_mapping_and_reports_admission_not_business_completion
    row = accept
    Growth::BillingExecution.new(row).call
    @requests << row.reload.subscription_sync_request_id
    assert_equal ['completed', 'subscription_accepted'], [row.state, row.result]
    request = Toybaco::SubscriptionSyncRequest.find(row.subscription_sync_request_id)
    assert_equal ['pending', 0], [request.state, request.completed_revision]
    Growth::BillingExecution.new(row).call
    assert_equal 1, request.reload.requested_revision
  end

  def test_checkout_pending_is_retried_and_only_verified_complete_is_finished
    row = accept(event(type: 'checkout.session.completed', reference: 'cs_test_ingress'))
    service = Object.new
    service.define_singleton_method(:complete!) { |_| 'payment_pending' }
    Growth::PurchaseFulfillment.stub(:new, service) { Growth::BillingExecution.new(row, client: Object.new).call }
    assert_equal ['pending', 1], [row.reload.state, row.attempts]
    refute_includes row.snapshot.to_json, 'never-retain'
    travel_to row.next_attempt_at
    service.define_singleton_method(:complete!) { |_| 'complete' }
    Growth::PurchaseFulfillment.stub(:new, service) { Growth::BillingExecution.new(row, client: Object.new).call }
    assert_equal ['completed', 'checkout_complete', 2], [row.reload.state, row.result, row.attempts]
  end

  def test_changed_mode_and_corrupt_reference_never_reach_provider
    row = accept
    ENV['TOYBACO_STRIPE_MODE'] = 'live'
    Growth::BillingExecution.new(row).call
    assert_equal ['attention', 'payment_mismatch'], [row.reload.state, row.result]
    assert_nil row.subscription_sync_request_id
  end

  def test_expired_processing_is_recovered_and_duplicate_event_does_not_reset_attention
    row = accept
    row.update!(state: 'processing', attempts: 47, lease_token: 'fixture', lease_expires_at: NOW - 1)
    travel_to NOW + 86_400
    Growth::BillingExecution.new(row).call
    assert_equal ['attention', 'retry_limit'], [row.reload.state, row.result]
    again = accept(event(reference: row.reference_id, id: row.event_id))
    assert_equal [row.id, 47, NOW + 86_400, 'attention'], [again.id, again.attempts, again.deadline_at, again.state]
  end

  def test_worker_death_on_last_attempt_and_corrupt_snapshot_fail_closed
    row = accept
    row.update!(state: 'processing', attempts: 48, lease_token: 'fixture', lease_expires_at: NOW - 1)
    Growth::BillingExecution.new(row).call
    assert_equal ['attention', 48, 'retry_limit'], [row.reload.state, row.attempts, row.result]
    corrupt = accept
    Toybaco::BillingEvent.connection.execute("UPDATE toybaco_billing_events SET payload_digest = '#{'0' * 64}' WHERE id = #{corrupt.id}")
    Growth::BillingExecution.new(corrupt.reload).call
    assert_equal ['attention', 'payment_mismatch'], [corrupt.reload.state, corrupt.result]
  end

  def test_database_rejects_half_mapping_and_preserves_the_referenced_request
    row = accept
    request = accept_subscription(row)
    assert_raises(ActiveRecord::StatementInvalid) do
      Toybaco::BillingEvent.connection.execute("UPDATE toybaco_billing_events SET requested_revision = NULL WHERE id = #{row.id}")
    end
    assert_equal [request.id, 1], [row.reload.subscription_sync_request_id, row.requested_revision]
    assert_raises(ActiveRecord::InvalidForeignKey) { request.destroy! }
    assert_equal row.id, Toybaco::BillingEvent.find(row.id).id
  end

  def test_independent_connections_accept_same_event_once_and_one_revision
    row = accept
    ids = Queue.new
    errors = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          current = Toybaco::BillingEvent.find(row.id)
          ids << Growth::BillingSubscription.accept!(current).id
        end
      rescue StandardError => error
        errors << error
      end
    end
    threads.each(&:join)
    raise errors.pop unless errors.empty?
    first, second = ids.pop, ids.pop
    @requests << first
    assert_equal first, second
    assert_equal 1, Toybaco::SubscriptionSyncRequest.find(first).requested_revision
    assert_equal 1, row.reload.requested_revision
  end
end
