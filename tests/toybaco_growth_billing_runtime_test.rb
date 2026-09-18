# frozen_string_literal: true

require 'rails/test_help'
require 'factory_bot_rails'
require Rails.root.join('lib/toybaco/subscription_sync')
require Rails.root.join('lib/toybaco/growth/ai_ledger')

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
    terms = Toybaco::PlanCatalog.default.definition(plan, '2026-09-18.1')
    price_id = "price_#{plan}"
    {
      'id' => 'sub_growth', 'status' => 'active', 'billing_cycle_anchor' => start_at.to_i,
      'items' => { 'has_more' => false, 'data' => [{
        'id' => 'si_growth', 'quantity' => 1, 'current_period_start' => start_at.to_i, 'current_period_end' => end_at.to_i,
        'price' => { 'id' => price_id, 'currency' => 'jpy', 'unit_amount' => terms.dig('cycles', cycle, 'amount'),
                     'recurring' => { 'interval' => cycle, 'interval_count' => 1 },
                     'metadata' => { 'toybaco_plan' => plan, 'toybaco_plan_version' => '2026-09-18.1' } }
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
end
