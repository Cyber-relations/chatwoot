# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../overlay/app/lib/toybaco/growth/monthly_window'
require_relative '../overlay/app/lib/toybaco/growth/allowance'
require_relative '../overlay/app/lib/toybaco/plan_catalog'
require_relative '../overlay/app/lib/toybaco/entitlements'

class ToybacoGrowthAllowanceTest < Minitest::Test
  Window = Toybaco::Growth::MonthlyWindow
  Allowance = Toybaco::Growth::Allowance
  VERSION = '2026-09-18.1'

  def window(anchor, now, ends_at: nil)
    Window.new(anchor: Time.iso8601(anchor), now: Time.iso8601(now), ends_at: ends_at && Time.iso8601(ends_at)).current
          &.transform_values { |value| Time.at(value).utc.iso8601 }
  end

  def test_january_31_anchor_recovers_after_short_february
    anchor = '2027-01-31T03:15:00Z'
    assert_equal({ 'starts_at' => '2027-02-28T03:15:00Z', 'ends_at' => '2027-03-31T03:15:00Z' }, window(anchor, '2027-03-01T00:00:00Z'))
    assert_equal({ 'starts_at' => '2027-03-31T03:15:00Z', 'ends_at' => '2027-04-30T03:15:00Z' }, window(anchor, '2027-03-31T03:15:00Z'))
  end

  def test_leap_year_and_utc_clock_are_preserved
    anchor = '2028-01-31T23:30:12Z'
    assert_equal '2028-02-29T23:30:12Z', window(anchor, '2028-02-29T23:30:11Z')['ends_at']
    assert_equal '2028-03-31T23:30:12Z', window(anchor, '2028-02-29T23:30:12Z')['ends_at']
  end

  def test_unpaid_future_and_expired_annual_periods_cannot_grant_usage
    anchor = '2026-09-18T02:00:00Z'
    assert_nil window(anchor, '2026-09-18T01:59:59Z')
    assert_nil window(anchor, '2027-09-18T02:00:00Z', ends_at: '2027-09-18T02:00:00Z')
    result = window(anchor, '2026-10-20T02:00:00Z', ends_at: '2026-10-21T02:00:00Z')
    assert_equal '2026-10-21T02:00:00Z', result['ends_at']
  end

  def test_annual_billing_produces_monthly_included_usage
    anchor = '2026-09-18T02:00:00Z'
    result = window(anchor, '2027-03-01T00:00:00Z', ends_at: '2027-09-18T02:00:00Z')
    assert_equal '2027-02-18T02:00:00Z', result['starts_at']
    assert_equal '2027-03-18T02:00:00Z', result['ends_at']
  end

  def test_mid_period_upgrade_adds_only_the_remaining_difference
    assert_equal 200, Allowance.upgrade(old_limit: 100, new_limit: 500, granted: 100, period_seconds: 1000, remaining_seconds: 500)
    assert_equal 1, Allowance.upgrade(old_limit: 100, new_limit: 500, granted: 100, period_seconds: 1000, remaining_seconds: 1)
    assert_equal 0, Allowance.upgrade(old_limit: 100, new_limit: 500, granted: 100, period_seconds: 1000, remaining_seconds: 0)
    assert_equal 10, Allowance.upgrade(old_limit: 100, new_limit: 500, granted: 490, period_seconds: 1000, remaining_seconds: 500)
  end

  def test_failed_renewal_grace_is_finite_and_proportional_to_that_period
    assert_equal 117, Allowance.grace(limit: 500, period_seconds: 30 * 86400)
    assert_equal 113, Allowance.grace(limit: 500, period_seconds: 31 * 86400)
    assert_equal 500, Allowance.grace(limit: 500, period_seconds: 5 * 86400)
    assert_raises(ArgumentError) { Allowance.grace(limit: 500, period_seconds: 0) }
  end

  def test_candidate_terms_do_not_change_current_sales_or_old_contracts
    catalog = Toybaco::PlanCatalog.default
    assert_equal [9800, 29800, 44800], catalog.sales.map { |plan| plan.dig('cycles', 'month', 'amount') }
    assert_equal [7980, 19800, 34800], %w[light standard pro].map { |id| catalog.definition(id, VERSION).dig('cycles', 'month', 'amount') }
    %w[free light standard pro].each do |id|
      terms = catalog.definition(id, VERSION)
      refute terms['sellable']
      assert_nil terms.dig('entitlements', 'limits', 'agents')
      assert_equal 1, terms.dig('entitlements', 'limits', 'stores')
      assert_raises(Toybaco::PlanCatalog::Invalid) { catalog.sale(id, 'month', version: VERSION) }
    end
    assert_equal 3, catalog.definition('light', '2026-09-06.1').dig('entitlements', 'limits', 'agents')
  end

  def test_free_has_no_stripe_subscription_and_upgrades_add_automation_or_volume
    catalog = Toybaco::PlanCatalog.default
    free = catalog.definition('free', VERSION)
    assert_empty free['cycles']
    contract = Toybaco::Entitlements.snapshot_for(free, cycle: nil)
    assert_nil contract['reference_price_id']
    assert_nil contract['cycle']
    assert_equal [20, 100, 500, 2000], %w[free light standard pro].map { |id| catalog.definition(id, VERSION).dig('entitlements', 'limits', 'ai_generations') }
    assert_equal [false, false, true, true], %w[free light standard pro].map { |id| catalog.definition(id, VERSION).dig('entitlements', 'features', 'ai_auto_reply') }
  end
end
