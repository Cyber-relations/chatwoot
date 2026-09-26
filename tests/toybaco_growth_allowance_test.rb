# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../overlay/app/lib/toybaco/growth/monthly_window'
require_relative '../overlay/app/lib/toybaco/growth/allowance'
require_relative '../overlay/app/lib/toybaco/plan_catalog'
require_relative '../overlay/app/lib/toybaco/entitlements'
require_relative '../overlay/app/lib/toybaco/growth/onboarding'
require_relative '../overlay/app/lib/toybaco/growth/pack_catalog'
require_relative '../overlay/app/lib/toybaco/growth/purchase_intent'
require_relative '../overlay/app/lib/toybaco/growth/retention_snapshot'

class ToybacoGrowthAllowanceTest < Minitest::Test
  Window = Toybaco::Growth::MonthlyWindow
  Allowance = Toybaco::Growth::Allowance
  VERSION = '2026-09-25.1'

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

  def test_sales_switch_sells_the_growth_version_and_keeps_old_contract_terms
    catalog = Toybaco::PlanCatalog.default
    assert_equal [[VERSION, 9800], [VERSION, 19_800], [VERSION, 29_800]],
                 catalog.sales.map { |plan| [plan['plan_version'], plan.dig('cycles', 'month', 'amount')] }
    %w[free light standard pro].each do |id|
      terms = catalog.definition(id, VERSION)
      assert_equal true, terms['sellable'], id
      assert_nil terms.dig('entitlements', 'limits', 'agents')
      assert_equal 1, terms.dig('entitlements', 'limits', 'stores')
    end
    %w[light standard pro].product(%w[month year]).each do |id, cycle|
      assert_equal VERSION, catalog.sale(id, cycle, version: VERSION)['plan_version']
    end
    # Free has no billing cycle: it opens by registration (free_registration_version), never as a cycle sale.
    %w[month year].each { |cycle| assert_raises(Toybaco::PlanCatalog::Invalid) { catalog.sale('free', cycle, version: VERSION) } }
    old = catalog.definition('light', '2026-09-06.1')
    assert_equal [false, 3, 9800], [old['sellable'], old.dig('entitlements', 'limits', 'agents'), old.dig('cycles', 'month', 'amount')]
    %w[month year].each { |cycle| assert_raises(Toybaco::PlanCatalog::Invalid) { catalog.sale('light', cycle, version: '2026-09-06.1') } }
  end

  def test_application_pins_one_growth_version_which_is_the_one_on_sale
    assert_equal '2026-09-25.1', Toybaco::GrowthTerms::VERSION
    pinned = [Toybaco::Growth::Onboarding, Toybaco::Growth::PackCatalog, Toybaco::Growth::PurchaseIntent, Toybaco::Growth::RetentionSnapshot]
    assert_equal [VERSION] * pinned.length, pinned.map { |owner| owner::VERSION }
    catalog = Toybaco::PlanCatalog.default
    candidate = catalog.data.fetch('release_candidates').fetch(VERSION)
    assert_equal %w[free light standard pro].to_h { |id| [id, VERSION] }, candidate.fetch('versions')
    # The sales switch (2026-09-26): the pinned version is the current sale, the free registration version and the
    # only sellable AI pack.
    assert_equal %w[light standard pro].to_h { |id| [id, VERSION] }, catalog.data.fetch('current_versions')
    assert_equal VERSION, catalog.data.fetch('free_registration_version')
    assert_equal true, Toybaco::Growth::PackCatalog.terms['sellable']
    assert_equal [VERSION], catalog.data.fetch('release_candidates').reject { |_, terms| terms.dig('ai_pack', 'sellable') == false }.keys
    # One sellable version per plan: superseded versions (2026-09-06.1 included) take no new applications.
    current = catalog.data.fetch('current_versions').merge('free' => VERSION)
    sellable = catalog.data.fetch('plans').flat_map do |id, plan|
      plan.fetch('versions').filter_map { |version, terms| [id, version] unless terms['sellable'] == false }
    end
    assert_equal current.to_a.sort, sellable.sort
    # Plan changes stay on the former version until the growth versions become eligible in their own slice.
    assert_equal %w[light standard pro].to_h { |id| [id, '2026-09-06.1'] }, catalog.data.dig('plan_changes', 'eligible_versions')
  end

  def test_lp_candidate_is_the_version_the_application_pins
    lp_path = File.expand_path('../scripts/lp_pricing_candidate.py', __dir__)
    skip 'LP 候補 script はこの品質スナップショットに含まれない' unless File.file?(lp_path)

    assert_equal [[Toybaco::GrowthTerms::VERSION]], File.read(lp_path).scan(/^VERSION = '([^']+)'$/)
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
