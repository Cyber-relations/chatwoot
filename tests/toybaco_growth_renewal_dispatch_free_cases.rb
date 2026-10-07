# frozen_string_literal: true

require Rails.root.join('lib/toybaco/growth/renewal_dispatch_execution')

# A renewal payment that never arrives: after the grace the dispatch row runs the stop (N2), the
# provider settlement (void, cancel), both holds and the Free write. Real database, dispatch rows,
# coordinator, settlement, holds and Free return; fixture Stripe, Postiz transport and connection
# inventory. Uses the continuation fixture (prepended before this module), with and without the
# in-app purchase record.
module ToybacoGrowthRenewalDispatchFreeCases
  Growth = Toybaco::Growth
  Dispatch = Growth::RenewalDispatch
  NOW = Time.utc(2026, 9, 24, 8)
  FLAGS = Growth::PeriodEndCancel::FLAGS
  HOLD_KEYS = [Growth::PostingRetention::KEY, Growth::InboxRetention::KEY].freeze

  def teardown
    if @free_fixture
      Toybaco::GrowthRenewalSettlement.where(account_id: @account.id).delete_all
      Toybaco::GrowthRenewalCoordinator.where(account_id: @account.id).delete_all
      Toybaco::GrowthPostingStop.where(account_id: @account.id).delete_all
    end
    super
  end

  # Three connections: Free keeps the two oldest inboxes and holds the newest one.
  def free_fixture(opening:)
    @free_fixture = true
    dispatch_ordinary_fixture(opening: opening)
    inboxes = 3.times.map { FactoryBot.create(:inbox, account: @account) }.sort_by(&:id)
    @free_kept = inboxes.first(2)
    rows = inboxes.each_with_index.map { |box, index| { 'id' => box.id.to_s, 'name' => 'private name', 'created_at_us' => (NOW.to_i * 1_000_000) + index } }
    @free_inventory = Struct.new(:rows) { def read = rows.deep_dup }.new({ 'inboxes' => rows, 'posting_accounts' => [], 'posts' => [] })
    @free_calls = []
    @free_postings = []
    @free_transport = lambda do |payload|
      raise 'the posting hold must run outside a transaction' if Account.connection.transaction_open?

      @free_postings << payload
      { 'version' => 1, 'request_sha256' => Digest::SHA256.hexdigest(JSON.generate(payload)),
        'organization_id' => payload.fetch('organization_id'), 'transition_id' => payload.fetch('transition_id'),
        'policy_hash' => payload.fetch('policy_hash'), 'receipt_hash' => 'b' * 64, 'kept_posts' => 0, 'held_posts' => 0 }
    end
    free_provider_actions
    assert_equal 'idle', free_execute(at: NOW)
    assert_equal 'grace_ready', dispatch_row.phase
  end

  # Voiding closes the invoice and cancelling ends the subscription, as Stripe answers.
  def free_provider_actions
    test = self
    @client.define_singleton_method(:void_invoice) do |id, idempotency_key:|
      raise 'provider called inside Account transaction' if Account.connection.transaction_open?
      raise 'missing deterministic idempotency key' unless idempotency_key.start_with?('toybaco-renewal-void-')

      test.instance_variable_get(:@free_calls) << [:void, id]
      test.instance_variable_get(:@subscription)['latest_invoice']['status'] = 'void'
    end
    @client.define_singleton_method(:cancel_unpaid_subscription) do |id|
      raise 'provider called inside Account transaction' if Account.connection.transaction_open?

      test.instance_variable_get(:@free_calls) << [:cancel, id]
      test.instance_variable_get(:@subscription)['status'] = 'canceled'
    end
  end

  def free_environment(changes = {})
    { 'TOYBACO_STRIPE_MODE' => 'test', 'TOYBACO_RENEWAL_SETTLEMENT_ENABLED' => 'true', 'TOYBACO_POSTING_STOP_ENABLED' => 'true',
      'TOYBACO_RENEWAL_PROVIDER_SETTLEMENT_ENABLED' => 'true', 'TOYBACO_POST_URL' => 'https://post.staging.toybaco.jp',
      'FRONTEND_URL' => 'https://app.staging.toybaco.jp', 'TOYBACO_OIDC_CLIENT_SECRET' => 'fixture-only-retention-secret-over-32-characters' }
      .merge(FLAGS.index_with { 'true' }).merge(changes)
  end

  def free_execute(at:, environment: free_environment, transport: @free_transport)
    travel_to at
    Growth::RetentionTransport.stub(:new, ->(**) { transport }) do
      Growth::RetentionInventory.stub(:new, ->(*, **) { @free_inventory }) do
        Growth::RenewalDispatchExecution.new(dispatch_row, client: @client, environment: environment, clock: -> { Time.now.utc }).call
      end
    end
  end

  def free_due = operation.due_at + 60
  def free_attrs = @account.reload.internal_attributes
  def free_coordinator = Toybaco::GrowthRenewalCoordinator.find_by!(renewal_operation_id: operation.id)
  def free_stop = Toybaco::GrowthPostingStop.find_by!(account_id: @account.id)
  def free_returns = Toybaco::GrowthFreeReturn.where(account_id: @account.id)

  # The store keeps its paid contract, subscription and stop until both holds and the Free write.
  def assert_free_not_written(label)
    attrs = free_attrs
    assert_equal [@dispatch_contract, @sub], attrs.values_at('toybaco_contract', 'toybaco_subscription_id'), label
    refute attrs.key?(Growth::InboxRetention::KEY), label
    refute attrs.key?(Growth::FreeReturnRecord::KEY), label
    assert_equal [0, 'pending', 'stop_recorded'], [free_returns.count, free_stop.state, free_coordinator.phase], label
  end

  { 'purchase_record' => false, 'opening_request' => true }.each do |label, opening|
    define_method("test_dispatch_free_unpaid_renewal_returns_to_free_with_both_holds_for_the_#{label}") do
      free_fixture(opening: opening)
      assert_equal 'idle', free_execute(at: free_due)
      assert_equal %w[idle free_completed], dispatch_row.values_at(:state, :phase)
      assert_equal [[:void, @invoice], [:cancel, @sub]], @free_calls
      attrs = free_attrs
      receipt = Growth::FreeReturnRecord.current(@account)
      journal = receipt.fetch('source_journal')
      assert_equal [Growth::FreeReturnRecord.free_contract, nil], [Toybaco::Entitlements.contract_for(@account), attrs['toybaco_subscription_id']]
      refute attrs.key?(Growth::PurchaseIntent::KEY)
      assert_equal(opening ? nil : { 'nonce' => 'a' * 48, 'state' => 'complete', 'subscription_id' => @sub, 'livemode' => false }, receipt['purchase'])
      assert_equal [[journal['id'], []]], @free_postings.map { |payload| payload.values_at('transition_id', 'keep_integration_ids') }
      assert_equal receipt['posting'], attrs[Growth::PostingRetention::KEY]
      assert_equal [journal['id'], @free_kept.map { |box| box.id.to_s }], attrs[Growth::InboxRetention::KEY].values_at('transition_id', 'keep_inbox_ids')
      assert_equal [1, 'applied', 'free_completed'], [free_returns.count, free_stop.state, free_coordinator.phase]
      assert_equal 'free_completed', Toybaco::GrowthRenewalSettlement.find_by!(coordinator_id: free_coordinator.id).phase
      assert_equal [20], Toybaco::GrowthAiGrant.where(account_id: @account.id, source: 'included').pluck(:units)
      refute Dispatch.blocked?('test', @sub, now: Time.now.utc)
      assert_equal 'idle', free_execute(at: free_due + 1.hour)
      assert_equal [1, 1, 2], [free_returns.count, @free_postings.size, @free_calls.size]
    end
  end

  # Each rollout flag alone keeps the provider-closed row pending: no hold, no Postiz call, no Free.
  def test_dispatch_free_half_open_rollout_stays_pending_without_holds
    free_fixture(opening: true)
    FLAGS.each_with_index do |flag, index|
      assert_equal 'pending', free_execute(at: free_due + (index * 5.minutes), environment: free_environment(flag => 'false')), flag
      assert_equal %w[pending provider_closed provider_closed], dispatch_row.values_at(:state, :phase, :result), flag
      assert_free_not_written(flag)
      refute free_attrs.key?(Growth::PostingRetention::KEY), flag
      assert_empty @free_postings, flag
    end
    assert_equal [[:void, @invoice], [:cancel, @sub]], @free_calls
    assert_equal 'idle', free_execute(at: free_due + 20.minutes)
    assert_equal %w[idle free_completed], dispatch_row.values_at(:state, :phase)
  end

  # A lost Postiz response is retried with the same transition, and the return completes once.
  def test_dispatch_free_lost_posting_response_is_pending_and_retries_the_same_transition
    free_fixture(opening: false)
    lost = lambda do |payload|
      @free_postings << payload
      raise Growth::RetentionProtocol::Invalid
    end
    assert_equal 'pending', free_execute(at: free_due, transport: lost)
    assert_equal %w[pending processing_unavailable], dispatch_row.values_at(:state, :result)
    assert_free_not_written('lost response')
    refute free_attrs.key?(Growth::PostingRetention::KEY)
    assert_equal 'idle', free_execute(at: free_due + 30.minutes)
    assert_equal %w[idle free_completed], dispatch_row.values_at(:state, :phase)
    journal = free_attrs[Growth::RenewalTransition::KEY]
    assert_equal [journal['id']] * 2, @free_postings.map { |payload| payload['transition_id'] }
    assert_equal 1, free_returns.count
  end

  # An opening store whose binding cannot be derived at the due time is never stopped: no coordinator,
  # posting stop, journal, Stripe call, hold or Free, and the row stops for an operator at its deadline.
  def test_dispatch_free_opening_store_without_a_binding_is_never_stopped_or_returned
    free_fixture(opening: true)
    Toybaco::OpeningRequest.where(id: @dispatch_opening_requests).delete_all
    assert_equal 'pending', free_execute(at: free_due)
    assert_equal 'processing_unavailable', dispatch_row.result
    refute Toybaco::GrowthRenewalCoordinator.exists?(renewal_operation_id: operation.id)
    refute Toybaco::GrowthPostingStop.exists?(account_id: @account.id)
    attrs = free_attrs
    assert_equal [@dispatch_contract, @sub], attrs.values_at('toybaco_contract', 'toybaco_subscription_id')
    refute(([Growth::RenewalTransition::KEY, Growth::FreeReturnRecord::KEY] + HOLD_KEYS).any? { |key| attrs.key?(key) })
    assert_equal [[], []], [@free_calls, @free_postings]
    assert_equal 'attention', free_execute(at: dispatch_row.deadline_at + 1)
    assert_equal %w[attention retry_limit], dispatch_row.values_at(:state, :result)
    assert_equal 0, free_returns.count
  end

  # A kept connection that disappeared after the choice stops the row for an operator: the inbox
  # hold and the Free write never happen, and the store keeps its paid contract and subscription.
  def test_dispatch_free_invalid_hold_needs_attention_and_writes_no_free
    free_fixture(opening: true)
    Inbox.where(id: @free_kept.first.id).delete_all
    assert_equal 'attention', free_execute(at: free_due)
    assert_equal %w[attention hold_attention], dispatch_row.values_at(:state, :result)
    assert_free_not_written('invalid hold')
    assert_equal 'provider_closed', free_attrs.dig(Growth::RenewalTransition::KEY, 'state')
    assert_equal 'attention', free_execute(at: free_due + 1.hour)
    assert_equal 0, free_returns.count
  end

  # The Free transition notice (the third renewal notice). The job the dispatch enqueues after the committed
  # Free write runs inline here, and the mailer is captured with a delivery that may fail. The notices flag
  # is the renewal reminder's. The dispatch fixture's owner was confirmed at the real clock, after NOW.
  def capture_free_notices(enabled: true, fail_delivery: false)
    queued = []
    sent = []
    delivery = Object.new
    delivery.define_singleton_method(:deliver_now) { raise 'fixture smtp timeout' if fail_delivery }
    mailer = lambda do |*args|
      sent << args
      delivery
    end
    job = lambda do |account_id|
      queued << account_id
      Toybaco::GrowthRenewalFreeNoticeJob.perform_now(account_id)
    end
    Growth::RenewalReminder.stub(:enabled?, enabled) do
      Toybaco::GrowthRenewalMailer.stub(:free_transition_notice, mailer) do
        Toybaco::GrowthRenewalFreeNoticeJob.stub(:perform_later, job) { yield queued, sent }
      end
    end
  end

  def confirm_free_owner!(at: NOW - 1.day)
    @dispatch_owner.update_columns(confirmed_at: at)
  end

  # The real mailer, with the sender the other notice tests use.
  def free_notice_mail(transition_id)
    with_free_notice_sender { Toybaco::GrowthRenewalMailer.free_transition_notice(@account.id, @dispatch_owner.id, transition_id).message }
  end

  def with_free_notice_sender
    old = ENV.fetch('MAILER_SENDER_EMAIL', nil)
    ENV['MAILER_SENDER_EMAIL'] = 'Toybaco <notice@example.invalid>'
    yield
  ensure
    old ? ENV['MAILER_SENDER_EMAIL'] = old : ENV.delete('MAILER_SENDER_EMAIL')
  end

  # The dispatch completes Free and enqueues the notice, which has not run yet. Returns the completed journal.
  def free_complete_before_the_notice
    queued = []
    Toybaco::GrowthRenewalFreeNoticeJob.stub(:perform_later, ->(account_id) { queued << account_id }) do
      assert_equal 'idle', free_execute(at: free_due)
    end
    assert_equal [[@account.id], %w[idle free_completed]], [queued, dispatch_row.values_at(:state, :phase)]
    free_attrs[Growth::RenewalTransition::KEY]
  end

  # A purchase after the Free return, as the fulfillment leaves the store: a paid contract and its subscription,
  # with the completed journal and the receipt of the return kept.
  def free_repurchase!
    @account.update_columns(internal_attributes: free_attrs.merge('toybaco_contract' => @dispatch_contract, 'toybaco_subscription_id' => @sub))
  end

  def free_notice_stage
    free_attrs.dig(Growth::RenewalReminder::KEY, 'stages', Growth::RenewalFreeNotice::STAGE)
  end

  # One notice when the dispatch completes Free, recorded in the renewal reminder's record of the same renewal.
  # A crashed claim of the completed row (the sweep reclaims it at its lease expiry) finds the transition complete
  # and enqueues again, and so does a repeated job: neither sends a second one.
  def test_dispatch_free_completion_sends_one_free_transition_notice_to_the_confirmed_owner
    free_fixture(opening: false)
    confirm_free_owner!
    capture_free_notices do |queued, sent|
      assert_equal 'idle', free_execute(at: free_due)
      journal = free_attrs[Growth::RenewalTransition::KEY]
      assert_equal [[@account.id], [[@account.id, @dispatch_owner.id, journal['id']]]], [queued, sent]
      failure = Growth::FreeReturnRecord.current(@account).dig('billing_history', Growth::RenewalGrace::FAILURE_KEY)
      assert_equal "#{failure['subscription_id']}:#{failure['term_start']}", free_attrs.dig(Growth::RenewalReminder::KEY, 'renewal')
      assert_equal ['attempted', @dispatch_owner.id, journal['id'], nil], free_notice_stage.values_at('state', 'user_id', 'transition_id', 'token')
      dispatch_row.update_columns(state: 'running', lease_token: 'f' * 48, lease_expires_at: free_due + 1.minute)
      assert_equal 'idle', free_execute(at: free_due + 1.hour)
      assert_equal %w[idle free_completed], dispatch_row.values_at(:state, :phase)
      Toybaco::GrowthRenewalFreeNoticeJob.perform_now(@account.id)
      assert_equal [[@account.id] * 2, 1], [queued, sent.size]
    end
  end

  # Disabled notices and an unconfirmed owner send nothing and claim nothing; the Free transition is the same.
  def test_dispatch_free_transition_notice_needs_the_notices_flag_and_a_confirmed_owner
    free_fixture(opening: true)
    confirm_free_owner!
    capture_free_notices(enabled: false) do |queued, sent|
      assert_equal 'idle', free_execute(at: free_due)
      assert_equal [[@account.id], []], [queued, sent]
    end
    assert_equal %w[idle free_completed], dispatch_row.values_at(:state, :phase)
    assert_nil free_notice_stage
    confirm_free_owner!(at: nil)
    capture_free_notices do |_queued, sent|
      Toybaco::GrowthRenewalFreeNoticeJob.perform_now(@account.id)
      assert_empty sent
    end
    assert_nil free_notice_stage
  end

  # An unknown SMTP result is uncertain and never sent again; the Free transition does not depend on it.
  def test_dispatch_free_transition_notice_with_an_unknown_smtp_result_is_never_resent
    free_fixture(opening: false)
    confirm_free_owner!
    capture_free_notices(fail_delivery: true) do |_queued, sent|
      assert_equal 'idle', free_execute(at: free_due)
      Toybaco::GrowthRenewalFreeNoticeJob.perform_now(@account.id)
      assert_equal 1, sent.size
    end
    assert_equal ['uncertain', nil], free_notice_stage.values_at('state', 'token')
    assert_equal [%w[idle free_completed], 1], [dispatch_row.values_at(:state, :phase), free_returns.count]
  end

  # The mail itself: the confirmed owner, the plan the store left, the Free limits of its contract, the inbox
  # the return held, the kept data and the billing page; no amount, card or Stripe ID. The recipient is checked again.
  def test_dispatch_free_transition_notice_mail_names_the_free_limits_and_held_connections_without_amounts_or_ids
    free_fixture(opening: false)
    confirm_free_owner!
    capture_free_notices(enabled: false) { assert_equal 'idle', free_execute(at: free_due) }
    journal = free_attrs[Growth::RenewalTransition::KEY]
    mail = free_notice_mail(journal['id'])
    assert_equal [[@dispatch_owner.email], '【トイバコ】お支払いが確認できなかったため無料プランへ移行しました'], [mail.to, mail.subject]
    text = mail.text_part.decoded
    ['お支払いが確認できなかったため無料プランへ移行しました。',
     "更新のお支払いを確認期限までに確認できなかったため、#{@dispatch_contract['name']} プランから無料プランへ移行しました。",
     '・プラン：無料プラン', '・無料プランの上限：受信箱 2 つ・投稿先 1 つ・AIアシスタント 月 20 回',
     '・上限を超えた受信箱 1 つは保留しました（削除はしていません）。', '会話・原稿・スタッフなどのデータは、そのまま残っています。',
     "/toybaco/billing?account_id=#{@account.id}", 'support@toybaco.jp'].each { |phrase| assert_includes text, phrase }
    refute_includes text, '投稿先 1 つは保留'
    html = mail.html_part.decoded
    assert_includes html, "/toybaco/billing?account_id=#{@account.id}"
    [text, html].each { |body| refute_match(/円|¥|\b(?:sub|in|cus|evt|pi|ch|price|si|card)_[A-Za-z0-9]/, body) }
    confirm_free_owner!(at: nil)
    assert_raises(RuntimeError) { free_notice_mail(journal['id']) }
  end

  # A purchase after the Free return keeps the completed journal and the receipt. A job that runs after it (a delayed
  # job, or an old one after a later renewal) sends nothing and claims nothing: the store is no longer on Free. Either
  # half of a purchase is enough: a paid contract without a subscription, or a subscription on the Free contract.
  def test_dispatch_free_transition_notice_is_not_sent_after_a_new_purchase
    free_fixture(opening: false)
    confirm_free_owner!
    free_complete_before_the_notice
    returned = free_attrs
    { 'paid contract and subscription' => [@dispatch_contract, @sub], 'paid contract only' => [@dispatch_contract, nil],
      'subscription only' => [returned['toybaco_contract'], @sub] }.each do |label, (contract, subscription)|
      @account.update_columns(internal_attributes: returned.merge('toybaco_contract' => contract, 'toybaco_subscription_id' => subscription))
      capture_free_notices do |_queued, sent|
        Toybaco::GrowthRenewalFreeNoticeJob.perform_now(@account.id)
        assert_empty sent, label
      end
      assert_nil free_notice_stage, label
    end
  end

  # The mail is built after the claim. A purchase in between makes the real mailer raise: no mail is built and the
  # notice is uncertain. (The delivery here only builds the real mail: this harness has no mail transport.)
  def test_dispatch_free_transition_notice_mail_raises_after_a_purchase_following_the_claim
    free_fixture(opening: false)
    confirm_free_owner!
    journal = free_complete_before_the_notice
    real = Toybaco::GrowthRenewalMailer.method(:free_transition_notice)
    built = []
    purchase_then_build = lambda do |*args|
      free_repurchase!
      delivery = Object.new
      delivery.define_singleton_method(:deliver_now) { built << real.call(*args).message }
      delivery
    end
    with_free_notice_sender do
      Growth::RenewalReminder.stub(:enabled?, true) do
        Toybaco::GrowthRenewalMailer.stub(:free_transition_notice, purchase_then_build) do
          Toybaco::GrowthRenewalFreeNoticeJob.perform_now(@account.id)
        end
      end
    end
    assert_equal [[], 'uncertain', nil], [built, *free_notice_stage.values_at('state', 'token')]
    error = assert_raises(RuntimeError) { free_notice_mail(journal['id']) }
    assert_equal 'store is no longer on Free', error.message
  end

  # The limits in the mail are the Free contract the store received in this transition (its receipt), not the
  # current contract.
  def test_dispatch_free_transition_notice_mail_reads_the_free_limits_from_the_transition_receipt
    free_fixture(opening: true)
    confirm_free_owner!
    journal = free_complete_before_the_notice
    attrs = free_attrs
    current = attrs['toybaco_contract'].deep_dup
    current['entitlements']['limits'].merge!('inboxes' => 9, 'posting_accounts' => 8, 'ai_generations' => 7)
    @account.update_columns(internal_attributes: attrs.merge('toybaco_contract' => current))
    contract = Toybaco::Entitlements.contract_for(@account.reload)
    shown = %w[inboxes posting_accounts ai_generations]
    assert_equal ['free', [9, 8, 7]], [contract['plan_id'], contract.dig('entitlements', 'limits').values_at(*shown)]
    limits = Growth::FreeReturnRecord.current(@account).dig('free_contract', 'entitlements', 'limits')
    assert_equal [2, 1, 20], limits.values_at(*shown)
    text = free_notice_mail(journal['id']).text_part.decoded
    assert_includes text, '・無料プランの上限：受信箱 2 つ・投稿先 1 つ・AIアシスタント 月 20 回'
    refute_includes text, '受信箱 9 つ'
  end

  # The limits are the receipt's as the mail is built: a receipt with other limits changes the mail (the catalog's
  # Free contract is not read). The stub covers the mail only.
  def test_dispatch_free_transition_notice_mail_follows_the_receipt_limits
    free_fixture(opening: true)
    confirm_free_owner!
    journal = free_complete_before_the_notice
    receipt = Growth::FreeReturnRecord.current(@account).deep_dup
    receipt['free_contract']['entitlements']['limits'].merge!('inboxes' => 3, 'posting_accounts' => 2, 'ai_generations' => 30)
    text = Growth::FreeReturnRecord.stub(:current, receipt) { free_notice_mail(journal['id']).text_part.decoded }
    assert_includes text, '・無料プランの上限：受信箱 3 つ・投稿先 2 つ・AIアシスタント 月 30 回'
  end

  # A completed journal with a cancel binding is a period-end cancellation's return: the job sends nothing and
  # claims nothing.
  def test_dispatch_free_transition_notice_is_not_sent_for_a_cancel_binding
    free_fixture(opening: true)
    confirm_free_owner!
    free_complete_before_the_notice
    attrs = free_attrs
    journal = attrs[Growth::RenewalTransition::KEY].deep_dup
    journal['binding']['cancel'] = { 'canceled_at' => NOW.to_i - 86_400, 'cancel_at' => NOW.to_i, 'ended_at' => NOW.to_i, 'reason' => nil }
    @account.update_columns(internal_attributes: attrs.merge(Growth::RenewalTransition::KEY => journal))
    capture_free_notices do |_queued, sent|
      Toybaco::GrowthRenewalFreeNoticeJob.perform_now(@account.id)
      assert_empty sent
    end
    assert_nil free_notice_stage
  end

  # A queue that cannot take the job (Redis down) keeps the dispatch result and is logged; nothing is sent or claimed.
  def test_dispatch_free_transition_notice_queue_failure_keeps_the_free_result_and_is_logged
    free_fixture(opening: false)
    confirm_free_owner!
    logged = []
    sent = []
    # Not nested in capture_free_notices: two stubs of the same method would not restore it.
    Toybaco::GrowthRenewalMailer.stub(:free_transition_notice, ->(*args) { sent << args }) do
      Toybaco::GrowthRenewalFreeNoticeJob.stub(:perform_later, ->(*) { raise RedisClient::CannotConnectError, 'fixture queue down' }) do
        Rails.logger.stub(:warn, ->(message = nil, &block) { logged << (message || block&.call) }) do
          assert_equal 'idle', free_execute(at: free_due)
        end
      end
    end
    assert_equal [[], %w[idle free_completed]], [sent, dispatch_row.values_at(:state, :phase)]
    assert_includes logged, "toybaco_renewal_free_notice_unqueued account=#{@account.id} class=RedisClient::CannotConnectError"
    assert_nil free_notice_stage
  end

  # An enqueue the adapter refuses (perform_later returns false) is a queue failure too: logged, the result stays.
  def test_dispatch_free_transition_notice_refused_enqueue_is_logged
    free_fixture(opening: false)
    confirm_free_owner!
    logged = []
    Toybaco::GrowthRenewalFreeNoticeJob.stub(:perform_later, false) do
      Rails.logger.stub(:warn, ->(message = nil, &block) { logged << (message || block&.call) }) do
        assert_equal 'idle', free_execute(at: free_due)
      end
    end
    assert_equal %w[idle free_completed], dispatch_row.values_at(:state, :phase)
    assert_includes logged, "toybaco_renewal_free_notice_unqueued account=#{@account.id} class=ActiveJob::EnqueueError"
    assert_nil free_notice_stage
  end

  # The claim counts only after its transaction committed. A COMMIT that fails after the write (the connection is
  # lost) rolls the claim back and is raised for the job's retry: nothing is sent, and the retry sends the one notice.
  def test_dispatch_free_transition_notice_claim_that_fails_to_commit_is_raised_for_a_retry
    free_fixture(opening: false)
    confirm_free_owner!
    free_complete_before_the_notice
    real_lock = @account.method(:with_lock)
    lost_commit = lambda do |*args, &block|
      real_lock.call(*args) do
        block.call
        raise ActiveRecord::ConnectionFailed, 'fixture connection lost at COMMIT'
      end
    end
    find_by = Account.method(:find_by)
    this_store = ->(*args, **conditions) { args.empty? && conditions == { id: @account.id } ? @account : find_by.call(*args, **conditions) }
    sent = []
    Growth::RenewalReminder.stub(:enabled?, true) do
      Toybaco::GrowthRenewalMailer.stub(:free_transition_notice, ->(*args) { sent << args }) do
        Account.stub(:find_by, this_store) do
          @account.stub(:with_lock, lost_commit) do
            assert_raises(ActiveRecord::ConnectionFailed) { Toybaco::GrowthRenewalFreeNoticeJob.perform_now(@account.id) }
          end
        end
      end
    end
    assert_equal [[], nil], [sent, free_notice_stage]
    capture_free_notices do |_queued, retry_sent|
      Toybaco::GrowthRenewalFreeNoticeJob.perform_now(@account.id)
      assert_equal 1, retry_sent.size
    end
    assert_equal 'attempted', free_notice_stage['state']
  end

  # A receipt that no longer reads (the Free terms changed after the return) is skipped with one log line: nothing is
  # sent or recorded, and the job ends without a retry.
  def test_dispatch_free_transition_notice_with_an_unreadable_receipt_is_skipped_with_a_log
    free_fixture(opening: false)
    confirm_free_owner!
    free_complete_before_the_notice
    logged = []
    capture_free_notices do |_queued, sent|
      Growth::FreeReturnRecord.stub(:current, ->(*) { raise Growth::FreeReturnRecord::Invalid }) do
        Rails.logger.stub(:warn, ->(message = nil, &block) { logged << (message || block&.call) }) do
          Toybaco::GrowthRenewalFreeNoticeJob.perform_now(@account.id)
        end
      end
      assert_empty sent
    end
    assert_nil free_notice_stage
    assert_equal ["toybaco_renewal_free_notice_skipped account=#{@account.id} reason=receipt-invalid"], logged.grep(/free_notice/)
  end

  # A failure before the claim (here the flag read) is raised again for the job's retry and claims nothing; the
  # retry sends the one notice.
  def test_dispatch_free_transition_notice_failure_before_the_claim_is_raised_for_a_retry
    free_fixture(opening: false)
    confirm_free_owner!
    free_complete_before_the_notice
    Growth::RenewalReminder.stub(:enabled?, -> { raise ActiveRecord::ConnectionNotEstablished, 'fixture database down' }) do
      assert_raises(ActiveRecord::ConnectionNotEstablished) { Toybaco::GrowthRenewalFreeNoticeJob.perform_now(@account.id) }
    end
    assert_nil free_notice_stage
    capture_free_notices do |_queued, sent|
      Toybaco::GrowthRenewalFreeNoticeJob.perform_now(@account.id)
      assert_equal 1, sent.size
    end
    assert_equal 'attempted', free_notice_stage['state']
  end

  # A Free write that rolls back (its completed journal fails the check inside the transaction) enqueues no
  # notice: the dispatch enqueues it only after the committed write.
  def test_dispatch_free_write_rolled_back_enqueues_no_notice
    free_fixture(opening: false)
    confirm_free_owner!
    capture_free_notices do |queued, sent|
      Growth::FreeReturnRecord.stub(:completed?, false) { assert_equal 'pending', free_execute(at: free_due) }
      assert_equal [[], []], [queued, sent]
    end
    assert_equal [0, 'provider_closed'], [free_returns.count, free_attrs.dig(Growth::RenewalTransition::KEY, 'state')]
    assert_equal [@dispatch_contract, @sub], free_attrs.values_at('toybaco_contract', 'toybaco_subscription_id')
    assert_nil free_notice_stage
  end

  # The hourly renewal reminder sweep, which also recovers a Free transition notice the dispatch could not enqueue.
  def free_sweep
    Toybaco::GrowthRenewalReminderSweepJob.perform_now
  end

  # The dispatch completes Free while the queue refuses the notice job (perform_later returns false), as in the
  # refused-enqueue case: no notice, no claim. Returns the completed journal.
  def free_complete_unqueued
    Toybaco::GrowthRenewalFreeNoticeJob.stub(:perform_later, false) { assert_equal 'idle', free_execute(at: free_due) }
    assert_equal %w[idle free_completed], dispatch_row.values_at(:state, :phase)
    assert_nil free_notice_stage
    free_attrs[Growth::RenewalTransition::KEY]
  end

  # (a) A notice job the queue refused is recovered by the next hourly sweep: one notice to the confirmed owner,
  # recorded attempted, and the sweep after it sends nothing more.
  def test_dispatch_free_reminder_sweep_sends_the_notice_a_refused_enqueue_left_behind
    free_fixture(opening: false)
    confirm_free_owner!
    journal = free_complete_unqueued
    travel_to free_due + 1.hour
    capture_free_notices do |queued, sent|
      free_sweep
      assert_equal [[], [[@account.id, @dispatch_owner.id, journal['id']]]], [queued, sent]
      travel_to free_due + 2.hours
      free_sweep
      assert_equal 1, sent.size
    end
    assert_equal ['attempted', @dispatch_owner.id, journal['id'], nil], free_notice_stage.values_at('state', 'user_id', 'transition_id', 'token')
  end

  # (b) After the dispatch's job sent the notice, the sweep finds its stage: nothing is sent and the record is the same.
  def test_dispatch_free_reminder_sweep_after_a_sent_notice_sends_nothing_and_keeps_the_record
    free_fixture(opening: true)
    confirm_free_owner!
    capture_free_notices do |_queued, sent|
      assert_equal 'idle', free_execute(at: free_due)
      assert_equal 1, sent.size
      record = free_attrs[Growth::RenewalReminder::KEY]
      travel_to free_due + 1.hour
      refute Growth::RenewalFreeNotice.pending?(@account.reload, now: Time.now.utc)
      free_sweep
      assert_equal [1, record], [sent.size, free_attrs[Growth::RenewalReminder::KEY]]
    end
  end

  # (c) The sweep sends and records nothing after a new purchase, for a cancel binding, for a Free return older than
  # the window, or with the notices flag off (read at the sweep); once none of those holds, it sends the one notice.
  def test_dispatch_free_reminder_sweep_skips_a_purchase_a_cancel_binding_an_old_return_and_a_closed_flag
    free_fixture(opening: false)
    confirm_free_owner!
    journal = free_complete_unqueued
    attrs = free_attrs
    cancel = journal.deep_dup
    cancel['binding']['cancel'] = { 'canceled_at' => NOW.to_i - 86_400, 'cancel_at' => NOW.to_i, 'ended_at' => NOW.to_i, 'reason' => nil }
    old = Time.at(journal['observed_at'] + Growth::RenewalFreeNotice::WINDOW + 1).utc
    [['purchase', -> { free_repurchase! }],
     ['cancel binding', -> { @account.update_columns(internal_attributes: attrs.merge(Growth::RenewalTransition::KEY => cancel)) }],
     ['old return', -> { travel_to old }]].each do |label, change|
      travel_to free_due + 1.hour
      change.call
      refute Growth::RenewalFreeNotice.pending?(@account.reload, now: Time.now.utc), label
      capture_free_notices do |_queued, sent|
        free_sweep
        assert_empty sent, label
      end
      assert_nil free_notice_stage, label
      @account.update_columns(internal_attributes: attrs)
    end
    travel_to free_due + 1.hour
    assert Growth::RenewalFreeNotice.pending?(@account.reload, now: Time.now.utc)
    capture_free_notices(enabled: false) do |_queued, sent|
      free_sweep
      assert_empty sent
    end
    assert_nil free_notice_stage
    capture_free_notices do |_queued, sent|
      free_sweep
      assert_equal 1, sent.size
    end
  end

  # (d) A store that fails before its claim (a lock wait) is logged and the sweep goes on: the next store is sent.
  def test_dispatch_free_reminder_sweep_logs_a_store_failing_before_its_claim_and_sends_the_next
    free_fixture(opening: false)
    confirm_free_owner!
    journal = free_complete_unqueued
    travel_to free_due + 1.hour
    locked = Account.create!(name: 'Locked fixture', locale: 'ja')
    locked.define_singleton_method(:with_lock) { |*| raise ActiveRecord::LockWaitTimeout, 'fixture lock wait' }
    stores = [locked, Account.find(@account.id)]
    candidates = Object.new
    candidates.define_singleton_method(:find_each) { |**, &block| stores.each(&block) }
    pending = Growth::RenewalFreeNotice.method(:pending?)
    logged = []
    capture_free_notices do |_queued, sent|
      Growth::RenewalFreeNotice.stub(:candidates, candidates) do
        Growth::RenewalFreeNotice.stub(:pending?, ->(account, now:) { account.equal?(locked) || pending.call(account, now: now) }) do
          Rails.logger.stub(:warn, ->(message = nil, &block) { logged << (message || block&.call) }) { free_sweep }
        end
      end
      assert_equal [[@account.id, @dispatch_owner.id, journal['id']]], sent
    end
    assert_equal ["toybaco_renewal_free_notice_sweep_failed account=#{locked.id} class=ActiveRecord::LockWaitTimeout"], logged.grep(/free_notice/)
    assert_equal 'attempted', free_notice_stage['state']
  ensure
    locked&.destroy!
  end

  # (e) pending? only reads: every statement is a SELECT (no BEGIN, lock or write), and it logs nothing, also for a
  # receipt that no longer reads (false, while perform keeps its own skip log).
  def test_dispatch_free_notice_pending_only_reads_and_logs_nothing
    free_fixture(opening: true)
    confirm_free_owner!
    free_complete_unqueued
    account = Account.find(@account.id)
    before = account.internal_attributes.deep_dup
    statements = []
    logged = []
    capture = ->(*, payload) { statements << payload[:sql] }
    results = Rails.logger.stub(:warn, ->(message = nil, &block) { logged << (message || block&.call) }) do
      ActiveSupport::Notifications.subscribed(capture, 'sql.active_record') do
        unreadable = Growth::FreeReturnRecord.stub(:current, ->(*) { raise Growth::FreeReturnRecord::Invalid }) do
          Growth::RenewalFreeNotice.pending?(account, now: Time.now.utc)
        end
        [Growth::RenewalFreeNotice.pending?(account, now: Time.now.utc), unreadable]
      end
    end
    assert_equal [true, false], results
    refute_empty statements
    assert statements.all? { |sql| sql.lstrip.start_with?('SELECT') }, statements.inspect
    assert_empty logged
    assert_equal before, @account.reload.internal_attributes
  end

  # (f) The reminder's record decides it: a free_transition stage in the record of this renewal makes pending? false;
  # a record of another renewal (the previous one's), or of this renewal without the stage, leaves it true, and the
  # sweep then replaces that record and sends the one notice.
  def test_dispatch_free_notice_pending_follows_the_stage_of_this_renewal_only
    free_fixture(opening: false)
    confirm_free_owner!
    free_complete_unqueued
    travel_to free_due + 1.hour
    failure = Growth::FreeReturnRecord.current(@account).dig('billing_history', Growth::RenewalGrace::FAILURE_KEY)
    renewal = "#{failure['subscription_id']}:#{failure['term_start']}"
    stage = { 'state' => 'attempted', 'user_id' => @dispatch_owner.id }
    previous = { 'renewal' => "#{@sub}:1", 'stages' => { Growth::RenewalFreeNotice::STAGE => stage } }
    attrs = free_attrs
    [[previous, true],
     [{ 'renewal' => renewal, 'stages' => { 'expired' => stage } }, true],
     [{ 'renewal' => renewal, 'stages' => { Growth::RenewalFreeNotice::STAGE => stage } }, false]].each do |record, expected|
      @account.update_columns(internal_attributes: attrs.merge(Growth::RenewalReminder::KEY => record))
      assert_equal expected, Growth::RenewalFreeNotice.pending?(@account.reload, now: Time.now.utc), record.inspect
    end
    @account.update_columns(internal_attributes: attrs.merge(Growth::RenewalReminder::KEY => previous))
    capture_free_notices do |_queued, sent|
      free_sweep
      assert_equal 1, sent.size
    end
    assert_equal [renewal, 'attempted'], [free_attrs.dig(Growth::RenewalReminder::KEY, 'renewal'), free_notice_stage['state']]
  end
end
