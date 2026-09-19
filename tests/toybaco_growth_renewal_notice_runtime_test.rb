# frozen_string_literal: true

require 'rails/test_help'
require 'minitest/mock'
require 'factory_bot_rails'
require Rails.root.join('lib/toybaco/growth/renewal_notice')
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
    ENV['TOYBACO_STRIPE_KEY'] = 'sk_test_fixture_renewal_notice'
    terms = Toybaco::PlanCatalog.default.definition('standard', '2026-09-18.1')
    contract = Toybaco::Entitlements.snapshot_for(terms, cycle: 'month').merge('stripe_price_id' => 'price_notice', 'subscription_item_id' => 'si_notice')
    Toybaco::Entitlements.apply!(@account, contract, subscription_id: 'sub_notice')
    paid = contract.slice('plan_id', 'plan_version', 'cycle', 'stripe_price_id').merge(
      'subscription_id' => 'sub_notice', 'paid_at' => (NOW - 30.days).to_i, 'term_start' => (NOW - 30.days).to_i,
      'term_end' => NOW.to_i, 'anchor' => (NOW - 30.days).to_i, 'normal_limit' => 500
    )
    failure = { 'subscription_id' => 'sub_notice', 'term_start' => NOW.to_i, 'term_end' => (NOW + 30.days).to_i,
                'first_failed_at' => NOW.to_i, 'grace_ends_at' => (NOW + 7.days).to_i, 'event_id' => 'evt_privatefailure' }
    @account.update!(internal_attributes: @account.internal_attributes.merge(
      Toybaco::BillingAccess::OWNER_KEY => @owner.id, Growth::PaidPeriod::KEY => paid, Growth::RenewalGrace::FAILURE_KEY => failure
    ))
    @subscription = {
      'id' => 'sub_notice', 'status' => 'past_due', 'items' => { 'has_more' => false, 'data' => [{
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
end
