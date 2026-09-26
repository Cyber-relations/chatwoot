# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/mock'
require 'active_support/testing/time_helpers'
require_relative 'toybaco_growth_purchase_stripe_fixture'
require_relative 'toybaco_opening_fixture'
require Rails.root.join('lib/toybaco/growth/opening_fulfillment')
require Rails.root.join('lib/toybaco/growth/billing_execution')

class ToybacoOpeningRuntimeTest < Minitest::Test
  include ActiveSupport::Testing::TimeHelpers
  Growth = Toybaco::Growth
  NOW = Time.utc(2026, 9, 24, 12)

  include ToybacoOpeningFixture

  def test_event_and_opening_mapping_are_minimal_idempotent_and_do_not_reset_budget
    first, second = accept, accept
    row = Growth::OpeningReceipt.bind!(first)
    row.update!(attempts: 23)
    travel_to NOW + 100
    again = Growth::OpeningReceipt.bind!(second)
    assert_equal [row.id, 23, NOW + 86_400], [again.id, again.attempts, again.deadline_at]
    refute_includes first.snapshot.to_json, @email
    refute_includes row.attributes.to_json, 'Opening fixture'
    assert_equal @session_id, row.session_id
  end

  def test_mapping_commit_failure_rolls_back_new_opening_and_recovers_same_event
    row = accept
    row.stub(:update!, ->(*) { raise IOError, 'fixture after insert' }) do
      assert_raises(IOError) { Growth::OpeningReceipt.bind!(row) }
    end
    refute Toybaco::OpeningRequest.exists?(session_id: @session_id)
    assert Growth::OpeningReceipt.bind!(row).persisted?
  end

  def test_fresh_paid_checkout_creates_exactly_one_store_with_catalog_rights_without_email
    row = accept
    assert_equal 'opening_account_ready', fulfill(row)
    saved = opening_request(row)
    account = Account.find(saved.account_id)
    assert_equal 'standard', Toybaco::Entitlements.contract_for(account)['plan_id']
    assert_equal [saved.owner_id], account.account_users.where(role: :administrator).pluck(:user_id)
    assert_equal 'pending', saved.onboarding_state
    assert_raises(ActiveRecord::ReadOnlyRecord) { saved.update!(account_id: account.id + 1) }
    saved.reload
    assert_equal 'opening_account_ready', fulfill(accept)
    assert_equal 1, Account.where("internal_attributes ->> 'toybaco_subscription_id' = ?", @sub_id).count
    refute ActiveJob::Base.queue_adapter.enqueued_jobs.any? { |job| job[:job].name.include?('MailDelivery') }
  end

  def test_opening_records_the_terms_version_consent_time_session_and_stripe_consent_once
    session = @client.sessions[@session_id]
    session['metadata'].merge!('toybaco_terms_version' => Toybaco::LegalTerms::VERSION, 'toybaco_terms_accepted_at' => '2026-09-24T11:58:00Z')
    session['consent'] = { 'terms_of_service' => 'accepted' }
    row = accept
    assert_equal 'opening_account_ready', fulfill(row)
    saved = opening_request(row)
    account = Account.find(saved.account_id)
    expected = [{ 'route' => 'opening_checkout', 'terms_version' => Toybaco::LegalTerms::VERSION, 'accepted_at' => '2026-09-24T11:58:00Z',
                  'user_id' => saved.owner_id, 'session_id' => @session_id, 'stripe_consent' => 'accepted' }]
    assert_equal expected, account.internal_attributes[Toybaco::LegalTerms::KEY]
    assert_equal 'opening_account_ready', fulfill(accept)
    assert_equal expected, account.reload.internal_attributes[Toybaco::LegalTerms::KEY]
  end

  def test_session_created_before_in_app_consent_opens_without_inventing_a_consent_record
    row = accept
    assert_equal 'opening_account_ready', fulfill(row)
    assert_nil Account.find(opening_request(row).account_id).internal_attributes[Toybaco::LegalTerms::KEY]
  end

  def test_malformed_consent_metadata_does_not_open_a_store
    @client.sessions[@session_id]['metadata'].merge!('toybaco_terms_version' => 'unknown', 'toybaco_terms_accepted_at' => 'yesterday')
    row = accept
    assert_raises(ArgumentError) { fulfill(row) }
    assert_nil opening_request(row).account_id
    refute User.exists?(email: @email)
  end

  def test_failure_after_store_insert_rolls_back_user_store_grants_and_request_binding
    row = accept
    request = Growth::OpeningReceipt.bind!(row)
    service = Growth::OpeningFulfillment.new(row, client: @client)
    service.stub(:apply_contract!, ->(*) { raise IOError, 'fixture after store insert' }) do
      assert_raises(IOError) { service.call }
    end
    refute User.exists?(email: @email)
    assert_equal ['pending', nil, nil], request.reload.values_at('state', 'account_id', 'subscription_id')
    assert_equal 'opening_account_ready', fulfill(row)
  end

  def test_post_commit_worker_result_loss_returns_original_store_even_with_flag_off
    row = accept
    execution = Growth::BillingExecution.new(row, client: @client)
    execution.stub(:finish!, ->(*) { raise IOError, 'fixture lost completion' }) { assert_raises(IOError) { execution.call } }
    account_id = opening_request(row).account_id
    ENV['TOYBACO_OPENING_INGRESS_ENABLED'] = 'false'
    travel_to NOW + 301
    Growth::BillingExecution.new(row, client: @client).call
    assert_equal ['completed', 'opening_account_ready'], row.reload.values_at('state', 'result')
    assert_equal account_id, opening_request(row).account_id
  end

  def test_stale_unpaid_canceled_or_foreign_mode_never_create_store
    row = accept
    session = @client.sessions[@session_id]
    session['payment_status'] = 'unpaid'
    assert_raises(Growth::OpeningTerms::Pending) { fulfill(row) }
    session['payment_status'] = 'paid'
    @client.subscriptions[@sub_id]['status'] = 'canceled'
    assert_raises(Growth::OpeningTerms::Pending) { fulfill(row) }
    @client.subscriptions[@sub_id]['status'] = 'active'
    session['livemode'] = true
    assert_raises(Growth::PaymentSignature::Invalid) { fulfill(row) }
    assert_nil opening_request(row).account_id
  end

  def test_provider_change_between_reads_rejects_without_partial_store
    row = accept
    original = @client.method(:retrieve_checkout_session)
    count = 0
    @client.define_singleton_method(:retrieve_checkout_session) do |id|
      value = original.call(id)
      count += 1
      value['customer_details']['email'] = 'changed@example.invalid' if count == 2
      value
    end
    assert_raises(Growth::PaymentSignature::Invalid) { fulfill(row) }
    assert_nil opening_request(row).account_id
  end

  def test_shared_opening_budget_and_attention_survive_distinct_notifications
    row = accept
    saved = Growth::OpeningReceipt.bind!(row)
    saved.update!(attempts: 48)
    assert_raises(Growth::PaymentSignature::Invalid) { fulfill(accept) }
    assert_equal ['attention', 48, NOW + 86_400], saved.reload.values_at('state', 'attempts', 'deadline_at')
    assert_raises(Growth::PaymentSignature::Invalid) { fulfill(accept) }
    assert_nil saved.reload.account_id
  end

  def test_receipt_survives_parent_deletion_and_old_event_does_not_recreate_store
    row = accept
    fulfill(row)
    saved = opening_request(row)
    Account.find(saved.account_id).destroy!
    assert Toybaco::OpeningRequest.exists?(saved.id)
    assert_equal 'opening_account_ready', fulfill(accept)
    refute Account.exists?(saved.account_id)
  end

  def test_outer_transaction_and_foreign_event_binding_reject
    row = accept
    Account.transaction { assert_raises(Growth::PaymentSignature::Invalid) { fulfill(row) } }
    assert_nil row.reload.opening_request_id
    Toybaco::BillingEvent.where(id: row.id).update_all(action: 'growth_checkout')
    row.reload
    assert_raises(Growth::PaymentSignature::Invalid) { Growth::OpeningReceipt.bind!(row) }
  end

  def test_independent_subscription_lock_prevents_race_before_store_write
    require 'pg'
    row = accept
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    other = PG.connect(host: config[:host], port: config[:port], dbname: config[:database],
                       user: config[:username], password: config[:password])
    key = Digest::SHA256.digest("toybaco:provision:#{@sub_id}").unpack1('q>')
    other.exec("SELECT pg_advisory_lock(#{key})")
    assert_raises(Growth::OpeningFulfillment::Busy) { fulfill(row) }
    assert_nil opening_request(row).account_id
    other.exec("SELECT pg_advisory_unlock(#{key})")
    assert_equal 'opening_account_ready', fulfill(row)
  ensure
    other&.finish
  end

  def test_database_rejects_partial_terminal_binding_and_outer_mapping
    row = accept
    saved = Growth::OpeningReceipt.bind!(row)
    assert_raises(ActiveRecord::StatementInvalid) do
      Toybaco::OpeningRequest.where(id: saved.id).update_all(state: 'account_ready')
    end
    Account.transaction { assert_raises(Growth::BillingReceipt::Conflict) { Growth::OpeningReceipt.bind!(row) } }
    travel_to NOW + 86_401
    assert_raises(Growth::PaymentSignature::Invalid) { fulfill(row) }
    assert_equal 'attention', saved.reload.state
  end

  def test_transient_provider_failure_is_retryable_without_new_receipt_or_store
    row = accept
    @client.stub(:retrieve_checkout_session, ->(*) { raise Toybaco::Checkout::Unavailable, 'fixture transport' }) do
      Growth::BillingExecution.new(row, client: @client).call
    end
    assert_equal ['pending', 1], row.reload.values_at('state', 'attempts')
    saved = opening_request(row)
    assert_equal ['pending', 1, nil], saved.values_at('state', 'attempts', 'account_id')
    travel_to NOW + 31
    Growth::BillingExecution.new(row, client: @client).call
    assert_equal 'completed', row.reload.state
    assert_equal saved.id, opening_request(row).id
  end

  def test_operations_hear_once_that_a_paid_store_opened_without_secrets
    mails = operations_mail do
      assert_equal 'opening_account_ready', fulfill(accept)
      assert_equal 'opening_account_ready', fulfill(accept)
    end
    saved = Toybaco::OpeningRequest.find_by!(session_id: @session_id)
    assert_equal 1, mails.size
    assert_equal ['ops@example.invalid'], mails.first.to
    assert_equal '【トイバコ】店舗を開通しました: Opening fixture', mails.first.subject
    body = mails.first.body.decoded
    ['決済を確認し、新しい店舗を作成しました。', '店舗名: Opening fixture', "店舗ID: #{saved.account_id}", "契約者: #{@email}",
     'プラン: スタンダード(契約版 2026-09-25.1・月払い)', '業種: 指定なし(業界パックは適用しません)', "Stripe: #{@session_id} / #{@sub_id}",
     'お客様へのログイン案内: 送信設定(GROWTH_NOTICES)が無効のため送られません。お客様へ個別にご連絡ください',
     '状況の確認: rake toybaco:opening_attention'].each { |line| assert_includes body, line }
    refute_match(/sk_(?:test|live)_|rk_(?:test|live)_|whsec_|pm_|password/i, body)
  end

  def test_operations_notice_does_not_depend_on_customer_notices_and_follows_the_staging_roster
    Growth::OpeningNotices.stub(:enabled?, true) do
      mails = operations_mail { fulfill(accept) }
      assert_includes mails.first.body.decoded, 'お客様へのログイン案内: 初期設定のあと自動で送ります'
    end
    ops = Growth::OpeningOperations
    production = { 'TOYBACO_DEPLOYMENT_ENVIRONMENT' => 'production' }
    assert_equal 'ops@example.invalid', ops.recipient(production.merge('TOYBACO_OPERATIONS_EMAIL' => ' Ops@Example.invalid '))
    [{}, { 'TOYBACO_OPERATIONS_EMAIL' => 'not-an-address' }, { 'TOYBACO_OPERATIONS_EMAIL' => 'a@example.invalid,b@example.invalid' }].each do |env|
      assert_nil ops.recipient(production.merge(env))
    end
    # production 以外(staging・未設定・綴り違い)は名簿必須。名簿が渡っていれば production でも名簿で絞る。
    [{ 'TOYBACO_DEPLOYMENT_ENVIRONMENT' => 'staging' }, {}, { 'TOYBACO_DEPLOYMENT_ENVIRONMENT' => 'Staging' },
     { 'TOYBACO_DEPLOYMENT_ENVIRONMENT' => 'prod' }, production].each do |env|
      base = env.merge('TOYBACO_OPERATIONS_EMAIL' => 'ops@example.invalid')
      assert_nil ops.recipient(base.merge('TOYBACO_STAGING_FIXTURE_EMAILS' => 'other@example.invalid')), env.inspect
      assert_equal 'ops@example.invalid', ops.recipient(base.merge('TOYBACO_STAGING_FIXTURE_EMAILS' => 'other@example.invalid, OPS@example.invalid')), env.inspect
      assert_nil ops.recipient(base), env.inspect unless env == production
    end
  end

  # アラーム(monitoring.tf の billing_attention)は、確認待ちの受付が残る間は毎分の sweep の出力で保たれる。
  def test_billing_sweep_repeats_the_attention_line_while_an_opening_receipt_needs_attention
    logged = lambda do
      io = StringIO.new
      Rails.stub(:logger, ActiveSupport::Logger.new(io)) { Growth::BillingReceipt.sweep(now: Time.now.utc) }
      io.string
    end
    marker = 'TOYBACO_BILLING_ATTENTION pending_receipts=true'
    others = Toybaco::BillingEvent.exists?(state: 'attention')
    others ? assert_includes(logged.call, marker) : refute_includes(logged.call, marker)
    @client.sessions[@session_id]['total_details'] = { 'amount_discount' => 1 }
    row = accept
    Growth::BillingExecution.new(row, client: @client).call
    assert_equal 'attention', row.reload.state
    2.times { assert_includes logged.call, marker }
  end

  def test_opening_without_an_operations_address_still_creates_the_store
    assert_empty operations_mail(address: '') { assert_equal 'opening_account_ready', fulfill(accept) }
    assert Toybaco::OpeningRequest.find_by!(session_id: @session_id).account_id
  end

  def test_operations_hear_when_a_paid_checkout_cannot_open_a_store
    @client.sessions[@session_id]['total_details'] = { 'amount_discount' => 1 }
    row = accept
    mails = operations_mail { Growth::BillingExecution.new(row, client: @client).call }
    assert_equal %w[attention payment_mismatch], row.reload.values_at('state', 'result')
    assert_nil opening_request(row).account_id
    assert_equal 1, mails.size
    assert_equal '【トイバコ】開通できませんでした(確認が必要)', mails.first.subject
    body = mails.first.body.decoded
    ["Checkout Session: #{@session_id}", '結果: payment_mismatch(決済の内容を開通の条件と照合できませんでした',
     "BillingEvent #{row.id} / OpeningRequest #{row.opening_request_id} / 試行 1 回",
     '未完の一覧: rake toybaco:billing_ingress_attention / rake toybaco:opening_attention'].each { |line| assert_includes body, line }
    refute_includes body, @email
  end

  def test_operations_hear_when_an_opening_receipt_expires_but_not_for_retryable_failures
    row = accept
    mails = operations_mail do
      @client.stub(:retrieve_checkout_session, ->(*) { raise Toybaco::Checkout::Unavailable, 'fixture transport' }) do
        Growth::BillingExecution.new(row, client: @client).call
      end
    end
    assert_equal ['pending', []], [row.reload.state, mails]
    travel_to NOW + 86_401
    mails = operations_mail { Growth::BillingExecution.new(row, client: @client).call }
    assert_equal %w[attention retry_limit], row.reload.values_at('state', 'result')
    assert_equal ['【トイバコ】開通できませんでした(確認が必要)'], mails.map(&:subject)
    assert_includes mails.first.body.decoded, '結果: retry_limit(再試行の上限または受付の期限(24時間)を過ぎました)'
  end

  def test_price_customer_metadata_and_paid_period_mismatches_do_not_create_store
    row = accept
    session = @client.sessions[@session_id]
    original = session.deep_dup
    [{ 'customer' => 'cus_other' }, { 'amount_subtotal' => 1 },
     { 'total_details' => { 'amount_discount' => 1 } },
     { 'metadata' => original['metadata'].merge('toybaco_plan' => 'pro') }].each do |change|
      @client.sessions[@session_id] = original.deep_dup.merge(change)
      assert_raises(Growth::PaymentSignature::Invalid) { fulfill(row) }
      assert_nil opening_request(row).account_id
    end
    @client.sessions[@session_id] = original
    @client.subscriptions[@sub_id]['latest_invoice']['lines']['has_more'] = true
    assert_raises(Growth::OpeningTerms::Pending) { fulfill(row) }
    assert_nil opening_request(row).account_id
  end
end
