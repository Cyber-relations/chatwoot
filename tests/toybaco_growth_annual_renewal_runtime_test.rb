# frozen_string_literal: true

require 'rails/test_help'
require 'minitest/mock'
require 'factory_bot_rails'
require Rails.root.join('lib/toybaco/growth/annual_renewal_reminder')

FactoryBot.find_definitions unless FactoryBot.factories.registered?(:account)

class ToybacoGrowthAnnualRenewalRuntimeTest < ActiveSupport::TestCase
  include FactoryBot::Syntax::Methods
  self.use_transactional_tests = true
  Growth = Toybaco::Growth
  ENDS = Time.utc(2027, 2, 9, 12)
  NOW = ENDS - 30.days
  Client = Struct.new(:data, :reads) do
    def retrieve_subscription(_id)
      self.reads += 1
      raise Toybaco::Checkout::Error, 'fixture unavailable' unless data
      data.deep_dup
    end
  end

  def setup
    travel_to NOW
    @old_sender = ENV['MAILER_SENDER_EMAIL']
    ENV['MAILER_SENDER_EMAIL'] = 'Toybaco <notice@example.invalid>'
    @account = create(:account)
    @owner = create(:user, :administrator, account: @account)
    terms = Toybaco::PlanCatalog.default.definition('standard', '2026-09-25.1')
    contract = Toybaco::Entitlements.snapshot_for(terms, cycle: 'year').merge('stripe_price_id' => 'price_annual', 'subscription_item_id' => 'si_annual')
    Toybaco::Entitlements.apply!(@account, contract, subscription_id: 'sub_annual')
    starts = (ENDS - 1.year).to_i
    item = { 'id' => 'si_annual', 'quantity' => 1, 'current_period_start' => starts, 'current_period_end' => ENDS.to_i,
             'price' => { 'id' => 'price_annual', 'currency' => 'jpy', 'recurring' => { 'interval' => 'year', 'interval_count' => 1 } } }
    invoice = { 'id' => 'in_annual', 'status' => 'paid', 'currency' => 'jpy', 'amount_remaining' => 0,
                'billing_reason' => 'subscription_cycle', 'subscription' => 'sub_annual', 'status_transitions' => { 'paid_at' => starts },
                'lines' => { 'has_more' => false, 'data' => [{ 'subscription_item' => 'si_annual', 'price' => { 'id' => 'price_annual' },
                  'quantity' => 1, 'amount' => 213840, 'period' => { 'start' => starts, 'end' => ENDS.to_i } }] } }
    @subscription = { 'id' => 'sub_annual', 'customer' => 'cus_annual', 'livemode' => ENV.fetch('TOYBACO_STRIPE_MODE', 'live') == 'live',
                      'status' => 'active', 'collection_method' => 'charge_automatically', 'cancel_at_period_end' => false,
                      'items' => { 'has_more' => false, 'data' => [item] }, 'latest_invoice' => invoice, 'billing_cycle_anchor' => starts }
    paid = Growth::PaidCoverage.new(@subscription, contract).verified
    @account.update!(internal_attributes: @account.internal_attributes.merge(
      Toybaco::BillingAccess::OWNER_KEY => @owner.id, Growth::PaidPeriod::KEY => paid, 'toybaco_stripe_customer_id' => 'cus_annual'
    ))
    @client = Client.new(@subscription, 0)
  end

  def teardown
    @old_sender ? ENV['MAILER_SENDER_EMAIL'] = @old_sender : ENV.delete('MAILER_SENDER_EMAIL')
    travel_back
    Current.reset
  end

  def remind(now: Time.current, enabled: true)
    Growth::RenewalReminder.stub(:enabled?, enabled) { Growth::AnnualRenewalReminder.new(@account, client: @client, now: now).perform }
  end

  def state
    @account.reload.internal_attributes.fetch(Growth::AnnualRenewalReminder::KEY, {})
  end

  def capture(fail_delivery: false)
    sent = []
    delivery = Object.new
    delivery.define_singleton_method(:deliver_now) { raise 'fixture SMTP uncertain' if fail_delivery }
    callback = ->(*args) { sent << args; delivery }
    Toybaco::GrowthAnnualRenewalMailer.stub(:reminder, callback) { yield sent }
  end

  def test_exact_thirty_and_seven_day_boundaries_each_dispatch_once
    before = @account.reload.internal_attributes.deep_dup
    capture do |sent|
      remind(now: NOW - 1)
      assert_empty sent
      assert_equal 0, @client.reads
      2.times { remind }
      assert_equal 1, sent.length
      assert_equal [@account.id, @owner.id, "sub_annual:#{ENDS.to_i}", 'thirty_days', ENDS.to_i], sent.first
      remind(now: ENDS - 7.days - 1)
      assert_equal 1, sent.length
      2.times { remind(now: ENDS - 7.days) }
      assert_equal %w[thirty_days seven_days], sent.map { |entry| entry[3] }
      remind(now: ENDS)
      assert_equal 2, sent.length
    end
    assert_equal before, @account.reload.internal_attributes.except(Growth::AnnualRenewalReminder::KEY)
    assert_empty Toybaco::GrowthAiGrant.where(account_id: @account.id)
  end

  def test_late_first_run_does_not_send_two_catchup_messages
    capture do |sent|
      remind(now: ENDS - 1.day)
      assert_equal ['seven_days'], sent.map { |entry| entry[3] }
      refute state.fetch('stages').key?('thirty_days')
    end
  end

  def test_disabled_or_unconfirmed_owner_does_not_read_provider
    capture do |sent|
      remind(enabled: false)
      @owner.update!(confirmed_at: nil)
      remind
      assert_empty sent
      assert_empty state
      assert_equal 0, @client.reads
    end
  end

  def test_recipient_removed_from_store_is_not_contacted
    @account.account_users.where(user_id: @owner.id).delete_all
    capture { |sent| remind; assert_empty sent }
    assert_equal 0, @client.reads
  end

  def test_suspended_monthly_legacy_or_unknown_paid_term_is_not_due
    @account.update!(status: 'suspended')
    capture { |sent| remind; assert_empty sent }
    @account.update!(status: 'active')
    original = @account.internal_attributes.deep_dup
    ['cycle', 'legacy', 'meter', 'paid'].each do |kind|
      attrs = original.deep_dup
      case kind
      when 'cycle' then attrs['toybaco_contract']['cycle'] = 'month'
      when 'legacy' then attrs['toybaco_contract']['legacy'] = true
      when 'meter' then attrs['toybaco_contract']['entitlements'].delete('ai_meter')
      when 'paid' then attrs.delete(Growth::PaidPeriod::KEY)
      end
      @account.update!(internal_attributes: attrs)
      capture { |sent| remind; assert_empty sent }
    end
    assert_equal 0, @client.reads
  end

  def test_cancelled_paused_scheduled_and_pending_update_contracts_are_not_reminded
    [{ 'cancel_at_period_end' => true }, { 'cancel_at' => ENDS.to_i }, { 'canceled_at' => NOW.to_i },
     { 'schedule' => 'sub_sched_later' }, { 'pending_update' => {} }, { 'pause_collection' => {} },
     { 'status' => 'canceled' }, { 'status' => 'past_due' }, { 'collection_method' => 'send_invoice' }].each do |change|
      @client.data = @subscription.merge(change)
      capture { |sent| remind; assert_empty sent }
      assert_empty state
    end
  end

  def test_wrong_customer_mode_identity_and_unpaid_invoice_do_not_dispatch
    [{ 'customer' => 'cus_other' }, { 'id' => 'sub_other' }, { 'livemode' => !@subscription['livemode'] },
     { 'latest_invoice' => @subscription['latest_invoice'].merge('status' => 'open') }].each do |change|
      @client.data = @subscription.merge(change)
      capture { |sent| remind; assert_empty sent }
      assert_empty state
    end
  end

  def test_latest_provider_period_and_items_must_still_match_the_paid_annual_contract
    original = @subscription.deep_dup
    ['price', 'year', 'count', 'period', 'extra'].each do |kind|
      @client.data = original.deep_dup
      item = @client.data['items']['data'].first
      case kind
      when 'price' then item['price']['id'] = 'price_other'
      when 'year' then item['price']['recurring']['interval'] = 'month'
      when 'count' then item['price']['recurring']['interval_count'] = 2
      when 'period' then item['current_period_end'] += 1.day
      when 'extra' then @client.data['items']['data'] << item.deep_dup.merge('id' => 'si_other')
      end
      capture { |sent| remind; assert_empty sent }
    end
  end

  def test_outage_before_claim_can_retry_but_uncertain_delivery_cannot
    @client.data = nil
    capture { |sent| remind; assert_empty sent }
    assert_empty state
    @client.data = @subscription
    capture(fail_delivery: true) do |sent|
      2.times { remind }
      assert_equal 1, sent.length
      assert_equal 'uncertain', state.dig('stages', 'thirty_days', 'state')
      refute state.dig('stages', 'thirty_days').key?('token')
    end
  end

  def test_process_stopped_after_claim_is_not_retried
    record = { 'renewal' => "sub_annual:#{ENDS.to_i}", 'stages' => { 'thirty_days' => { 'state' => 'dispatching', 'token' => 'fixture' } } }
    @account.update!(internal_attributes: @account.internal_attributes.merge(Growth::AnnualRenewalReminder::KEY => record))
    capture { |sent| remind; assert_empty sent }
    assert_equal record, state
  end

  def test_new_annual_term_has_its_own_notice_identity
    capture { |sent| remind; assert_equal 1, sent.length }
    next_end = ENDS + 1.year
    @subscription['items']['data'].first.merge!('current_period_start' => ENDS.to_i, 'current_period_end' => next_end.to_i)
    invoice = @subscription['latest_invoice']
    invoice['id'] = 'in_nextannual'
    invoice['status_transitions']['paid_at'] = ENDS.to_i
    invoice['lines']['data'].first['period'] = { 'start' => ENDS.to_i, 'end' => next_end.to_i }
    paid = Growth::PaidCoverage.new(@subscription, Toybaco::Entitlements.contract_for(@account)).verified
    @account.update!(internal_attributes: @account.internal_attributes.merge(Growth::PaidPeriod::KEY => paid))
    capture do |sent|
      remind(now: next_end - 30.days)
      assert_equal 1, sent.length
      assert_equal "sub_annual:#{next_end.to_i}", state['renewal']
    end
  end

  def test_real_mailer_uses_japan_time_and_rechecks_current_owner_and_claim
    record = { 'renewal' => "sub_annual:#{ENDS.to_i}", 'stages' => { 'thirty_days' => { 'state' => 'dispatching', 'user_id' => @owner.id } } }
    @account.update!(internal_attributes: @account.internal_attributes.merge(Growth::AnnualRenewalReminder::KEY => record))
    args = [@account.id, @owner.id, record['renewal'], 'thirty_days', ENDS.to_i]
    mail = Toybaco::GrowthAnnualRenewalMailer.reminder(*args).message
    assert_equal [@owner.email], mail.to
    assert_includes mail.text_part.decoded, '2027年2月9日 21:00'
    assert_includes mail.html_part.decoded, "/toybaco/billing?account_id=#{@account.id}"
    refute_includes mail.encoded, 'sub_annual'
    @account.update!(internal_attributes: @account.internal_attributes.merge('toybaco_subscription_id' => 'sub_replaced'))
    assert_raises(RuntimeError) { Toybaco::GrowthAnnualRenewalMailer.reminder(*args).message }
    @account.update!(internal_attributes: @account.internal_attributes.merge('toybaco_subscription_id' => 'sub_annual'))
    record['stages']['thirty_days']['state'] = 'attempted'
    @account.update!(internal_attributes: @account.internal_attributes.merge(Growth::AnnualRenewalReminder::KEY => record))
    assert_raises(RuntimeError) { Toybaco::GrowthAnnualRenewalMailer.reminder(*args).message }
  end
end
