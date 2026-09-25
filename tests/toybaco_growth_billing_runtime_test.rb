# frozen_string_literal: true

require 'rails/test_help'
require 'factory_bot_rails'
require Rails.root.join('lib/toybaco/subscription_sync')
require Rails.root.join('lib/toybaco/growth/ai_ledger')
require Rails.root.join('lib/toybaco/growth/renewal_failure_receipt')

FactoryBot.find_definitions unless FactoryBot.factories.registered?(:account)

class ToybacoGrowthBillingRuntimeTest < ActiveSupport::TestCase
  include FactoryBot::Syntax::Methods
  self.use_transactional_tests = true
  Ledger = Toybaco::Growth::AiLedger
  NOW = Time.utc(2026, 9, 18, 12)
  Client = Struct.new(:data) do
    def retrieve_subscription(_id)
      data
    end
  end

  def setup
    @account = create(:account)
    @account.update!(internal_attributes: { 'toybaco_subscription_id' => 'sub_growth' })
    @client = Client.new
  end

  def subscription(plan: 'standard', cycle: 'month', start_at: Time.utc(2026, 9, 3, 12), end_at: Time.utc(2026, 10, 3, 12), paid_at: start_at, invoice_id: 'in_initial')
    terms = Toybaco::PlanCatalog.default.definition(plan, '2026-09-25.1')
    price_id = "price_#{plan}"
    {
      'id' => 'sub_growth', 'status' => 'active', 'billing_cycle_anchor' => start_at.to_i,
      'items' => { 'has_more' => false, 'data' => [{
        'id' => 'si_growth', 'quantity' => 1, 'current_period_start' => start_at.to_i, 'current_period_end' => end_at.to_i,
        'price' => { 'id' => price_id, 'currency' => 'jpy', 'unit_amount' => terms.dig('cycles', cycle, 'amount'),
                     'recurring' => { 'interval' => cycle, 'interval_count' => 1 },
                     'metadata' => { 'toybaco_plan' => plan, 'toybaco_plan_version' => '2026-09-25.1' } }
      }] },
      'latest_invoice' => {
        'id' => invoice_id, 'status' => 'paid', 'currency' => 'jpy', 'amount_remaining' => 0,
        'billing_reason' => invoice_id == 'in_initial' ? 'subscription_create' : 'subscription_update',
        'parent' => { 'subscription_details' => { 'subscription' => 'sub_growth' } },
        'status_transitions' => { 'paid_at' => paid_at.to_i },
        'lines' => { 'has_more' => false, 'data' => [{
          'quantity' => 1, 'amount' => 19800, 'period' => { 'start' => paid_at.to_i, 'end' => end_at.to_i },
          'parent' => { 'subscription_item_details' => { 'subscription_item' => 'si_growth' } },
          'pricing' => { 'price_details' => { 'price' => price_id } }
        }] }
      }
    }
  end

  def synchronize(data, now: NOW)
    @client.data = data
    travel_to(now) do
      Toybaco::SubscriptionSync.new(client: @client).call(@account, subscription_id: 'sub_growth')
    end
  end

  def remaining(now = NOW)
    Ledger.new(@account, now: now).summary['remaining']
  end

  def buckets
    Toybaco::GrowthAiGrant.where(account_id: @account.id).order(:starts_at, :id)
  end

  def test_monthly_quota_uses_actual_stripe_period_and_stops_without_next_payment
    data = subscription(end_at: Time.utc(2026, 10, 4, 12))
    assert_equal 'applied', synchronize(data)
    assert_equal 500, remaining
    assert_equal Time.utc(2026, 9, 3, 12), buckets.first.starts_at
    assert_equal Time.utc(2026, 10, 4, 12), buckets.first.ends_at
    assert_equal 0, remaining(Time.utc(2026, 10, 4, 12))
    assert_equal 1, buckets.count
  end

  def test_yearly_payment_renews_monthly_from_original_anchor_without_a_years_quota
    data = subscription(cycle: 'year', start_at: Time.utc(2026, 1, 31, 12), end_at: Time.utc(2027, 1, 31, 12))
    synchronize(data)
    assert_equal 500, remaining
    assert_equal Time.utc(2026, 8, 31, 12), buckets.first.starts_at
    assert_equal 500, remaining(Time.utc(2026, 9, 30, 12))
    assert_equal Time.utc(2026, 10, 31, 12), buckets.last.ends_at
    assert_equal 1000, buckets.sum(:units)
  end

  def test_paid_upgrade_keeps_usage_adds_only_remaining_fraction_and_is_idempotent
    synchronize(subscription)
    buckets.first.update!(used: 400)
    upgraded = subscription(plan: 'pro', paid_at: NOW, invoice_id: 'in_upgrade')
    3.times { synchronize(upgraded) }
    assert_equal 850, remaining
    assert_equal 1250, buckets.sum(:units)
    assert_equal 400, buckets.sum(:used)
    assert_equal 2, buckets.count
  end

  def test_unpaid_or_unrelated_invoice_does_not_grant_new_ai_units
    unpaid = subscription
    unpaid['latest_invoice']['status'] = 'open'
    synchronize(unpaid)
    assert_equal 0, remaining
    unrelated = subscription
    unrelated['latest_invoice']['parent']['subscription_details']['subscription'] = 'sub_another'
    synchronize(unrelated)
    assert_equal 0, remaining
    assert_empty buckets
  end

  def test_next_paid_month_gets_full_allowance_and_old_used_units_remain_recorded
    synchronize(subscription)
    buckets.first.update!(used: 400)
    next_start = Time.utc(2026, 10, 3, 12)
    data = subscription(start_at: next_start, end_at: Time.utc(2026, 11, 3, 12), invoice_id: 'in_renewal')
    data['latest_invoice']['billing_reason'] = 'subscription_cycle'
    synchronize(data, now: next_start)
    assert_equal 500, remaining(next_start)
    assert_equal 400, buckets.sum(:used)
    assert_equal 2, buckets.count
  end

  def test_paid_activation_revokes_free_remainder_but_retains_purchased_pack
    Toybaco::Growth::AiGrants.new(@account).issue!(source: 'included', source_key: 'free:fixture:anchor', units: 20, starts_at: NOW - 60, ends_at: NOW + 86400)
    Toybaco::Growth::AiGrants.new(@account).issue!(source: 'pack', source_key: 'pack:fixture', units: 500, starts_at: NOW - 60, ends_at: NOW + 86400)
    synchronize(subscription)
    assert_equal 1000, remaining
    assert_not_nil buckets.find_by!(source_key: 'free:fixture:anchor').revoked_at
    assert_nil buckets.find_by!(source_key: 'pack:fixture').revoked_at
  end

  def test_unpaid_initial_invoice_keeps_free_features_and_does_not_start_automatic_replies
    terms = Toybaco::PlanCatalog.default.definition('free', '2026-09-25.1')
    Toybaco::Entitlements.apply!(@account, Toybaco::Entitlements.snapshot_for(terms, cycle: nil))
    before = Toybaco::Entitlements.contract_for(@account)
    data = subscription
    data['latest_invoice']['status'] = 'open'
    data['latest_invoice']['amount_remaining'] = 19800
    assert_equal 'payment_pending', synchronize(data)
    assert_equal before, Toybaco::Entitlements.contract_for(@account.reload)
    refute Toybaco::Entitlements.for_account(@account).dig('features', 'ai_auto_reply')
    assert_equal 20, Toybaco::Entitlements.for_account(@account).dig('limits', 'ai_generations')
    assert_empty buckets
  end

  def test_active_subscription_with_unpaid_upgrade_keeps_paid_rights_and_usage_until_payment
    synchronize(subscription)
    buckets.first.update!(used: 400)
    data = subscription(plan: 'pro', paid_at: NOW, invoice_id: 'in_upgrade')
    data['latest_invoice']['status'] = 'open'
    data['latest_invoice']['amount_remaining'] = 7500
    2.times { assert_equal 'payment_pending', synchronize(data) }
    assert_equal 'standard', Toybaco::Entitlements.contract_for(@account.reload)['plan_id']
    assert_equal 100, remaining
    assert_equal 500, buckets.sum(:units)
    assert_equal 400, buckets.sum(:used)
    data['latest_invoice']['status'] = 'paid'
    data['latest_invoice']['amount_remaining'] = 0
    assert_equal 'applied', synchronize(data)
    assert_equal 'pro', Toybaco::Entitlements.contract_for(@account.reload)['plan_id']
    assert_equal 850, remaining
    assert_equal 400, buckets.sum(:used)
  end

  def test_changed_paid_rights_require_an_invoice_for_the_same_subscription_and_current_period
    synchronize(subscription)
    before = Toybaco::Entitlements.contract_for(@account)
    invalid = subscription(plan: 'pro', paid_at: NOW, invoice_id: 'in_upgrade')
    invalid['latest_invoice']['parent']['subscription_details']['subscription'] = 'sub_other'
    future = subscription(plan: 'pro', start_at: NOW + 86400, end_at: NOW + 40 * 86400)
    expired = subscription(plan: 'pro', start_at: NOW - 40 * 86400, end_at: NOW)
    future_payment = subscription(plan: 'pro', paid_at: NOW + 60, invoice_id: 'in_upgrade')
    [invalid, future, expired, future_payment].each do |data|
      assert_equal 'payment_pending', synchronize(data)
      assert_equal before, Toybaco::Entitlements.contract_for(@account.reload)
      assert_equal 500, remaining
    end
  end

  def test_same_contract_renewal_failure_keeps_existing_rights_without_granting_a_new_period
    synchronize(subscription)
    before = Toybaco::Entitlements.contract_for(@account)
    boundary = Time.utc(2026, 10, 3, 12)
    data = subscription(start_at: boundary, end_at: Time.utc(2026, 11, 3, 12), invoice_id: 'in_renewal')
    data['status'] = 'past_due'
    data['latest_invoice'].merge!('status' => 'open', 'amount_remaining' => 19800, 'billing_reason' => 'subscription_cycle')
    assert_equal 'applied', synchronize(data, now: boundary)
    assert_equal before, Toybaco::Entitlements.contract_for(@account.reload)
    assert @account.active?
    assert_equal 0, remaining(boundary)
    assert_equal 1, buckets.count
  end

  def test_payment_pending_does_not_restore_a_suspended_account
    synchronize(subscription)
    @account.update!(status: :suspended, internal_attributes: @account.internal_attributes.merge('toybaco_billing_suspended' => true))
    data = subscription(plan: 'pro', paid_at: NOW, invoice_id: 'in_upgrade')
    data['latest_invoice']['status'] = 'open'
    assert_equal 'payment_pending', synchronize(data)
    assert @account.reload.suspended?
    assert_equal 'standard', Toybaco::Entitlements.contract_for(@account)['plan_id']
  end

  def prepare_renewal(cycle: 'month')
    boundary = Time.utc(2026, 10, 3, 12)
    old_start = cycle == 'month' ? Time.utc(2026, 9, 3, 12) : Time.utc(2025, 10, 3, 12)
    synchronize(subscription(cycle: cycle, start_at: old_start, end_at: boundary))
    @account.update!(internal_attributes: @account.reload.internal_attributes.merge('toybaco_stripe_customer_id' => 'cus_growth'))
    ending = cycle == 'month' ? boundary + 30.days : Time.utc(2027, 10, 3, 12)
    data = subscription(cycle: cycle, start_at: boundary, end_at: ending, invoice_id: 'in_renewal')
    data.merge!('customer' => 'cus_growth', 'livemode' => false, 'status' => 'past_due', 'billing_cycle_anchor' => old_start.to_i)
    data['latest_invoice'].merge!('status' => 'open', 'amount_remaining' => 19800, 'billing_reason' => 'subscription_cycle')
    synchronize(data, now: boundary)
    [boundary, data]
  end

  def record_failure(data, created:, now: created, attempt: 1, event_id: 'evt_gracefirst')
    event = { 'created' => created.to_i, 'livemode' => false, 'data' => { 'object' => {
      'id' => data['latest_invoice']['id'], 'subscription' => data['id'], 'customer' => 'cus_growth', 'attempt_count' => attempt
    } } }
    receipt = Struct.new(:snapshot, :event_id).new(event, event_id)
    old_mode = ENV['TOYBACO_STRIPE_MODE']
    ENV['TOYBACO_STRIPE_MODE'] = 'test'
    @client.data = data
    Toybaco::Growth::RenewalFailureReceipt.new(receipt, client: @client, now: now).record!
  ensure
    old_mode ? ENV['TOYBACO_STRIPE_MODE'] = old_mode : ENV.delete('TOYBACO_STRIPE_MODE')
  end

  def grace_bucket
    buckets.find_by!(source: 'grace')
  end

  def reserve_at(now, kind: 'reply_draft')
    Ledger.new(@account, now: now).reserve(request_key: SecureRandom.hex(16), kind: kind, context_digest: 'a' * 64)
  end

  def consume_at(reservation, now, &block)
    Ledger.new(@account, now: now).settle(operation_id: reservation.fetch('operation_id'), token: reservation.fetch('token'),
                                        outcome: 'consumed', &(block || -> { 'draft:grace' }))
  end

  def mark_paid(data, at:)
    data['status'] = 'active'
    data['latest_invoice'].merge!('status' => 'paid', 'amount_remaining' => 0, 'status_transitions' => { 'paid_at' => at.to_i })
    synchronize(data, now: at)
  end

  def test_renewal_grace_is_117_of_500_for_thirty_days_and_is_not_reissued
    boundary, data = prepare_renewal
    assert_equal 'first_failure_recorded', record_failure(data, created: boundary)
    3.times { assert_equal 117, remaining(boundary) }
    original_id = grace_bucket.id
    assert_equal 'consumed', consume_at(reserve_at(boundary), boundary)['result']
    assert_equal 'first_failure_already_recorded', record_failure(data, created: boundary, now: boundary + 2.days)
    assert_equal 116, remaining(boundary + 2.days)
    assert_equal original_id, grace_bucket.id
    assert_equal boundary + 7.days, grace_bucket.ends_at
  end

  def test_grace_requires_previous_paid_coverage_and_a_known_first_attempt
    boundary, data = prepare_renewal
    assert_equal 'awaiting_first_failure', record_failure(data, created: boundary, attempt: 2)
    assert_equal 0, remaining(boundary)
    record_failure(data, created: boundary)
    @account.update!(internal_attributes: @account.reload.internal_attributes.except(Toybaco::Growth::PaidPeriod::KEY))
    assert_equal 0, remaining(boundary)
    assert_equal 0, buckets.where(source: 'grace').count
  end

  def test_grace_does_not_start_at_late_delivery_or_repeat_in_an_unpaid_month
    boundary, data = prepare_renewal
    record_failure(data, created: boundary, now: boundary + 8.days)
    assert_equal 0, remaining(boundary + 8.days)
    item = data['items']['data'].first
    item['current_period_start'] = (boundary + 30.days).to_i
    item['current_period_end'] = (boundary + 60.days).to_i
    data['latest_invoice']['id'] = 'in_nextunpaid'
    assert_equal 'first_failure_already_recorded', record_failure(data, created: boundary + 30.days)
    assert_equal 0, remaining(boundary + 30.days)
    assert_equal 0, buckets.where(source: 'grace').count
  end

  def test_grace_payment_promotes_same_bucket_preserving_used_and_reserved_units
    boundary, data = prepare_renewal
    record_failure(data, created: boundary)
    consumed = reserve_at(boundary)
    consume_at(consumed, boundary)
    pending = reserve_at(boundary)
    original_id = grace_bucket.id
    mark_paid(data, at: boundary + 60)
    assert_equal 498, remaining(boundary + 60)
    promoted = buckets.find(original_id)
    assert_equal ['included', 500, 1, boundary + 30.days], [promoted.source, promoted.units, promoted.used, promoted.ends_at]
    assert_equal 'consumed', consume_at(pending, boundary + 60)['result']
    2.times { mark_paid(data, at: boundary + 60) }
    assert_equal 498, remaining(boundary + 60)
    assert_equal 1, buckets.where(source_key: promoted.source_key).count
  end

  def test_grace_expiry_stops_an_in_flight_automatic_reply_before_its_lease_ends
    boundary, data = prepare_renewal
    record_failure(data, created: boundary)
    request = reserve_at(boundary + 7.days - 1, kind: 'automatic_reply')
    published = false
    result = consume_at(request, boundary + 7.days) { published = true; 'reply:must-not-send' }
    assert_equal 'released', result['result']
    refute published
    assert_equal 0, remaining(boundary + 7.days)
    assert_equal 0, grace_bucket.used
  end

  def test_payment_after_grace_expiry_still_keeps_grace_usage_in_paid_allowance
    boundary, data = prepare_renewal
    record_failure(data, created: boundary)
    consume_at(reserve_at(boundary), boundary)
    assert_equal 0, remaining(boundary + 7.days)
    mark_paid(data, at: boundary + 8.days)
    assert_equal 499, remaining(boundary + 8.days)
    assert_equal 1, buckets.where(source: 'included').sum(:used)
  end

  def test_earlier_first_failure_tightens_existing_grace_without_resetting_usage
    boundary, data = prepare_renewal
    record_failure(data, created: boundary + 1.day)
    consume_at(reserve_at(boundary + 1.day), boundary + 1.day)
    original_id = grace_bucket.id
    record_failure(data, created: boundary, now: boundary + 2.days, event_id: 'evt_graceearlier')
    assert_equal 116, remaining(boundary + 2.days)
    assert_equal [original_id, boundary, boundary + 7.days, 1], [grace_bucket.id, grace_bucket.starts_at, grace_bucket.ends_at, grace_bucket.used]
    assert_equal 0, remaining(boundary + 7.days)
  end

  def test_yearly_renewal_grace_uses_one_month_not_a_year_and_never_rolls_over
    boundary, data = prepare_renewal(cycle: 'year')
    record_failure(data, created: boundary)
    assert_equal 113, remaining(boundary)
    assert_equal 113, grace_bucket.units
    assert_equal 0, remaining(boundary + 7.days)
    assert_equal 0, remaining(Time.utc(2026, 11, 3, 12))
    assert_equal 1, buckets.where(source: 'grace').count
  end

  def test_grace_precedes_packs_and_expiry_keeps_previously_purchased_draft_units
    boundary, data = prepare_renewal
    record_failure(data, created: boundary)
    Toybaco::Growth::AiGrants.new(@account).issue!(source: 'pack', source_key: 'pack:kept', units: 500,
                                                 starts_at: boundary - 1.day, ends_at: boundary + 20.days)
    consume_at(reserve_at(boundary), boundary)
    assert_equal 1, grace_bucket.used
    assert_equal 0, buckets.find_by!(source: 'pack').used
    assert_equal 500, remaining(boundary + 7.days)
    assert_equal 'denied', reserve_at(boundary + 7.days, kind: 'automatic_reply')['result']
    assert_equal 'reserved', reserve_at(boundary + 7.days)['result']
  end

  def test_suspended_or_changed_contract_cannot_spend_an_existing_grace_bucket
    boundary, data = prepare_renewal
    record_failure(data, created: boundary)
    assert_equal 117, remaining(boundary)
    @account.update!(status: :suspended)
    assert_equal 0, remaining(boundary)
    @account.update!(status: :active)
    terms = Toybaco::PlanCatalog.default.definition('free', '2026-09-25.1')
    Toybaco::Entitlements.apply!(@account, Toybaco::Entitlements.snapshot_for(terms, cycle: nil))
    assert_equal 0, remaining(boundary)
    assert_equal 1, buckets.where(source: 'grace').count
  end

  def test_other_subscription_or_noncontiguous_paid_period_cannot_receive_grace
    boundary, data = prepare_renewal
    record_failure(data, created: boundary)
    attrs = @account.reload.internal_attributes
    paid = attrs.fetch(Toybaco::Growth::PaidPeriod::KEY)
    [{ 'subscription_id' => 'sub_other' }, { 'term_end' => boundary.to_i - 1 }, { 'paid_at' => boundary.to_i + 1 }].each do |change|
      @account.update!(internal_attributes: attrs.merge(Toybaco::Growth::PaidPeriod::KEY => paid.merge(change)))
      assert_equal 0, remaining(boundary)
    end
    assert_equal 0, buckets.where(source: 'grace').count
  end

  def test_missing_previous_paid_record_does_not_bypass_seven_day_automatic_reply_stop
    boundary, data = prepare_renewal
    record_failure(data, created: boundary)
    @account.update!(internal_attributes: @account.reload.internal_attributes.except(Toybaco::Growth::PaidPeriod::KEY))
    Toybaco::Growth::AiGrants.new(@account).issue!(source: 'pack', source_key: 'pack:retained', units: 500,
                                                 starts_at: boundary, ends_at: boundary + 30.days)
    assert_equal 500, remaining(boundary + 7.days)
    assert_equal 'denied', reserve_at(boundary + 7.days, kind: 'automatic_reply')['result']
  end

  def test_yearly_first_attempt_later_than_first_ai_month_does_not_create_another_grace_bucket
    boundary, data = prepare_renewal(cycle: 'year')
    late = Time.utc(2026, 11, 4, 12)
    record_failure(data, created: late)
    assert_equal 0, remaining(late)
    assert_equal 0, buckets.where(source: 'grace').count
    Toybaco::Growth::AiGrants.new(@account).issue!(source: 'pack', source_key: 'pack:late', units: 500,
                                                 starts_at: boundary, ends_at: boundary + 90.days)
    assert_equal 'denied', reserve_at(late + 7.days, kind: 'automatic_reply')['result']
  end
end
