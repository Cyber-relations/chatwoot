# frozen_string_literal: true

require 'rails/test_help'
require 'minitest/mock'
require 'factory_bot_rails'
require Rails.root.join('lib/toybaco/growth/renewal_notice')
require Rails.root.join('lib/toybaco/growth/renewal_reminder')
require Rails.root.join('lib/toybaco/checkout/plan_change')

FactoryBot.find_definitions unless FactoryBot.factories.registered?(:account)

class ToybacoGrowthRenewalNoticeRuntimeTest < ActionDispatch::IntegrationTest
  include FactoryBot::Syntax::Methods
  self.use_transactional_tests = true
  NOW = Time.utc(2026, 10, 3, 12)
  Growth = Toybaco::Growth
  Client = Struct.new(:data) do
    def retrieve_subscription(_id)
      raise Toybaco::Checkout::Error, 'fixture unavailable' unless data

      data
    end
  end

  def setup
    travel_to NOW
    @account = create(:account)
    @owner = create(:user, :administrator, account: @account)
    @user = @owner
    @old_key = ENV['TOYBACO_STRIPE_KEY']
    @old_sender = ENV['MAILER_SENDER_EMAIL']
    ENV['MAILER_SENDER_EMAIL'] = 'Toybaco <notice@example.invalid>'
    ENV['TOYBACO_STRIPE_KEY'] = 'sk_test_fixture_renewal_notice'
    terms = Toybaco::PlanCatalog.default.definition('standard', '2026-09-18.1')
    contract = Toybaco::Entitlements.snapshot_for(terms, cycle: 'month').merge('stripe_price_id' => 'price_notice', 'subscription_item_id' => 'si_notice')
    Toybaco::Entitlements.apply!(@account, contract, subscription_id: 'sub_notice')
    paid = contract.slice('plan_id', 'plan_version', 'cycle', 'stripe_price_id').merge(
      'subscription_id' => 'sub_notice', 'paid_at' => (NOW - 30.days).to_i, 'term_start' => (NOW - 30.days).to_i,
      'term_end' => NOW.to_i, 'anchor' => (NOW - 30.days).to_i, 'normal_limit' => 500
    )
    failure = { 'subscription_id' => 'sub_notice', 'term_start' => NOW.to_i, 'term_end' => (NOW + 30.days).to_i,
                'first_failed_at' => NOW.to_i, 'grace_ends_at' => (NOW + 7.days).to_i, 'event_id' => 'evt_privatefailure',
                'invoice_id' => 'in_privaterenewal' }
    @account.update!(internal_attributes: @account.internal_attributes.merge(
      Toybaco::BillingAccess::OWNER_KEY => @owner.id, Growth::PaidPeriod::KEY => paid, Growth::RenewalGrace::FAILURE_KEY => failure,
      'toybaco_stripe_customer_id' => 'cus_notice'
    ))
    @subscription = {
      'id' => 'sub_notice', 'customer' => 'cus_notice', 'livemode' => ENV.fetch('TOYBACO_STRIPE_MODE', 'live') == 'live',
      'status' => 'past_due', 'items' => { 'has_more' => false, 'data' => [{
        'id' => 'si_notice', 'quantity' => 1, 'current_period_end' => (NOW + 30.days).to_i,
        'price' => { 'id' => 'price_notice', 'unit_amount' => 19800, 'currency' => 'jpy',
                     'tax_behavior' => 'exclusive', 'recurring' => { 'interval' => 'month' } }
      }] },
      'latest_invoice' => { 'id' => 'in_privaterenewal', 'status' => 'open', 'currency' => 'jpy', 'billing_reason' => 'subscription_cycle',
                            'subscription' => 'sub_notice', 'amount_remaining' => 21780, 'total' => 21780, 'amount_paid' => 0 }
    }
  end

  def teardown
    @old_key ? ENV['TOYBACO_STRIPE_KEY'] = @old_key : ENV.delete('TOYBACO_STRIPE_KEY')
    @old_sender ? ENV['MAILER_SENDER_EMAIL'] = @old_sender : ENV.delete('MAILER_SENDER_EMAIL')
    travel_back
    Current.reset
  end

  def show_billing
    reader = Struct.new(:user).new(@user)
    changes = Struct.new(:state).new({})
    Toybaco::Oidc::SessionReader.stub(:new, reader) do
      Toybaco::Checkout::Client.stub(:new, Client.new(@subscription)) do
        Toybaco::Checkout::PlanChange.stub(:new, changes) { get "/toybaco/billing?account_id=#{@account.id}" }
      end
    end
  end

  def test_owner_sees_signed_deadline_in_japan_time_and_existing_payment_action_without_writes
    before = @account.reload.internal_attributes.deep_dup
    show_billing
    assert_response :ok
    assert_select '#renewal-heading', text: '更新のお支払いをご確認ください'
    assert_select '.renewal-notice time[datetime="2026-10-10T12:00:00Z"]', text: '2026年10月10日 21:00（日本時間）'
    assert_select '.renewal-notice a[href="#portal"]', text: '支払い方法を確認'
    assert_select '#portal', count: 1
    refute_includes response.body, 'evt_privatefailure'
    refute_includes response.body, 'in_privaterenewal'
    assert_equal before, @account.reload.internal_attributes
    assert_empty Toybaco::GrowthAiGrant.where(account_id: @account.id)
  end

  def test_expired_notice_and_feature_badge_agree_that_automatic_replies_are_stopped
    travel_to NOW + 7.days
    show_billing
    assert_response :ok
    assert_select '.renewal-notice', text: /自動応答を一時停止しています。/
    assert_select '.badge.off', text: '支払い確認まで停止'
    refute_includes response.body, '利用可能（設定後に開始）'
  end

  def test_fresh_paid_void_or_different_invoice_is_not_overridden_by_old_failure_receipt
    [%w[status paid], %w[status void], %w[subscription sub_other], %w[billing_reason subscription_update]].each do |key, value|
      original = @subscription['latest_invoice'].deep_dup
      @subscription['latest_invoice'][key] = value
      show_billing
      assert_response :ok
      assert_select '.renewal-notice', count: 0
      @subscription['latest_invoice'] = original
    end
  end

  def test_provider_outage_does_not_present_a_cached_deadline_as_current
    @subscription = nil
    show_billing
    assert_response :ok
    assert_select '.renewal-notice', count: 0
    assert_includes response.body, '現在の請求情報を取得できません'
  end

  def test_unknown_first_failure_does_not_invent_a_deadline
    @account.update!(internal_attributes: @account.internal_attributes.except(Growth::RenewalGrace::FAILURE_KEY))
    show_billing
    assert_response :ok
    assert_select '.renewal-notice', count: 0
  end

  def test_store_admin_who_is_not_billing_owner_cannot_see_the_notice_or_payment_action
    @user = create(:user, :administrator, account: @account)
    show_billing
    assert_response :forbidden
    assert_select '.renewal-notice', count: 0
    assert_select '#portal', count: 0
  end

  def remind(now: Time.current, enabled: true)
    Growth::RenewalReminder.stub(:enabled?, enabled) do
      Growth::RenewalReminder.new(@account, client: Client.new(@subscription), now: now).perform
    end
  end

  def reminder_state
    @account.reload.internal_attributes.fetch(Growth::RenewalReminder::KEY, {})
  end

  def capture_reminders(fail_delivery: false)
    captured = []
    delivery = Object.new
    delivery.define_singleton_method(:deliver_now) { raise 'fixture smtp timeout' if fail_delivery }
    callback = lambda do |*args|
      captured << args
      delivery
    end
    Toybaco::GrowthRenewalMailer.stub(:reminder, callback) { yield captured }
  end

  def test_renewal_reminder_sends_once_per_stage_without_resetting_deadline_or_ai_allowance
    before = @account.reload.internal_attributes.deep_dup
    capture_reminders do |sent|
      2.times { remind }
      assert_equal 1, sent.length
      assert_equal [@account.id, @owner.id, 'initial', '2026-10-10T12:00:00Z'], sent.first
      assert_equal 'attempted', reminder_state.dig('stages', 'initial', 'state')
      2.times { remind(now: NOW + 7.days) }
      assert_equal 2, sent.length
      assert_equal 'expired', sent.last[2]
      assert_equal 'attempted', reminder_state.dig('stages', 'expired', 'state')
    end
    assert_equal before, @account.reload.internal_attributes.except(Growth::RenewalReminder::KEY)
    assert_empty Toybaco::GrowthAiGrant.where(account_id: @account.id)
  end

  def test_renewal_reminder_with_unknown_smtp_result_is_never_automatically_resent
    capture_reminders(fail_delivery: true) do |sent|
      2.times { remind }
      assert_equal 1, sent.length
      assert_equal 'uncertain', reminder_state.dig('stages', 'initial', 'state')
      refute reminder_state.dig('stages', 'initial').key?('token')
    end
  end

  def test_disabled_renewal_reminders_do_not_read_stripe_or_write_receipts
    @subscription = nil
    before = @account.reload.internal_attributes.deep_dup
    capture_reminders do |sent|
      remind(enabled: false)
      assert_empty sent
    end
    assert_equal before, @account.reload.internal_attributes
  end

  def test_renewal_reminder_outage_can_recover_without_claiming_a_delivery
    @subscription, original = nil, @subscription
    capture_reminders do |sent|
      remind
      assert_empty sent
      assert_empty reminder_state
      @subscription = original
      remind
      assert_equal 1, sent.length
    end
  end

  def test_paid_or_replaced_invoice_cancels_old_renewal_reminders
    @subscription['latest_invoice']['status'] = 'paid'
    capture_reminders do |sent|
      remind
      remind(now: NOW + 7.days)
      assert_empty sent
    end
    assert_equal 'cancelled', reminder_state.dig('stages', 'initial', 'state')
    assert_equal 'cancelled', reminder_state.dig('stages', 'expired', 'state')
  end

  def test_replaced_invoice_and_wrong_customer_or_mode_never_receive_a_reminder
    [[:invoice, 'in_other'], [:customer, 'cus_other'], [:mode, !@subscription['livemode']]].each do |kind, value|
      original = @subscription.deep_dup
      case kind
      when :invoice then @subscription['latest_invoice']['id'] = value
      when :customer then @subscription['customer'] = value
      when :mode then @subscription['livemode'] = value
      end
      @account.update!(internal_attributes: @account.internal_attributes.except(Growth::RenewalReminder::KEY))
      capture_reminders { |sent| remind; assert_empty sent }
      @subscription = original
    end
  end

  def test_recipient_must_still_be_confirmed_and_hold_the_billing_access
    @owner.update!(confirmed_at: nil)
    capture_reminders do |sent|
      remind
      assert_empty sent
      assert_empty reminder_state.fetch('stages')
      assert_equal (NOW + 1.hour).to_i, reminder_state.fetch('next_check_at')
      @owner.update!(confirmed_at: NOW)
      remind(now: NOW + 1.hour)
      assert_equal 1, sent.length
    end
  end

  def test_old_process_dispatching_state_never_requeues_an_unknown_email
    record = { 'renewal' => "sub_notice:#{NOW.to_i}", 'stages' => { 'initial' => { 'state' => 'dispatching', 'token' => 'fixture' } } }
    @account.update!(internal_attributes: @account.internal_attributes.merge(Growth::RenewalReminder::KEY => record))
    capture_reminders { |sent| remind; assert_empty sent }
    assert_equal record, reminder_state
  end

  def test_first_reminder_after_deadline_sends_only_the_expired_notice
    capture_reminders do |sent|
      remind(now: NOW + 7.days)
      assert_equal ['expired'], sent.map { |item| item[2] }
      refute reminder_state.fetch('stages').key?('initial')
    end
  end

  def test_mailer_rechecks_recipient_before_using_current_email_and_has_only_the_billing_link
    mail = Toybaco::GrowthRenewalMailer.reminder(@account.id, @owner.id, 'initial', '2026-10-10T12:00:00Z').message
    assert_equal [@owner.email], mail.to
    assert_includes mail.text_part.decoded, '2026年10月10日 21:00'
    assert_includes mail.html_part.decoded, "/toybaco/billing?account_id=#{@account.id}"
    refute_includes mail.encoded, 'in_privaterenewal'
    @account.account_users.where(user_id: @owner.id).delete_all
    assert_raises(RuntimeError) do
      Toybaco::GrowthRenewalMailer.reminder(@account.id, @owner.id, 'initial', '2026-10-10T12:00:00Z').message
    end
  end
end
