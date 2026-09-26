# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../overlay/app/lib/toybaco/plan_catalog'
require_relative '../overlay/app/lib/toybaco/entitlements'
require_relative '../overlay/app/lib/toybaco/agent_seat_limit'
require_relative '../overlay/app/lib/toybaco/checkout'

class ToybacoPlanCatalogTest < Minitest::Test
  Catalog = Toybaco::PlanCatalog
  Entitlements = Toybaco::Entitlements
  Account = Struct.new(:internal_attributes, :features) do
    def with_lock
      yield
    end

    def enable_features!(name)
      features[name] = true
    end

    def disable_features!(name)
      features[name] = false
    end

    def update!(internal_attributes:)
      self.internal_attributes = internal_attributes
    end
  end

  # The sales version before the 2026-09-26 sales switch. Its contracts keep their terms after the switch.
  FORMER = '2026-09-06.1'
  CURRENT = '2026-09-25.1'

  def data
    JSON.parse(File.read(Catalog::PATH))
  end

  # The catalog as it stood before the sales switch: FORMER on sale and eligible for plan changes. The plan change
  # policy is reachable only for a version that is both, so its mechanism is exercised on this state.
  def before_switch_data
    changed = data
    %w[light standard pro].each do |id|
      changed['current_versions'][id] = FORMER
      changed['plans'][id]['versions'][FORMER]['sellable'] = true
    end
    %w[free light standard pro].each { |id| changed['plans'][id]['versions'][CURRENT]['sellable'] = false }
    changed['release_candidates'][CURRENT]['ai_pack']['sellable'] = false
    changed.delete('free_registration_version')
    changed
  end

  def snapshot(id = 'light', catalog: Catalog.default, cycle: 'month')
    Entitlements.snapshot_for(catalog.sale(id, cycle), cycle: cycle)
  end

  # A contract purchased under FORMER (formerly the current sale) is resolved by its version, not by current sales.
  def purchased(id = 'light', cycle: 'month')
    Entitlements.snapshot_for(Catalog.default.definition(id, FORMER), cycle: cycle)
  end

  def test_projection_builds_final_attributes_without_mutating_input_or_saving_an_account
    contract = snapshot
    attrs = { 'toybaco_subscription_id' => 'sub_original', 'unrelated' => { 'value' => true },
              'postiz' => { 'organization_id' => 'existing-org', 'enabled' => true } }
    original = Marshal.load(Marshal.dump([attrs, contract]))
    projected = Entitlements.project_attributes(attrs, contract, subscription_id: 'sub_next')
    assert_equal original, [attrs, contract]
    assert_equal 'sub_next', projected['toybaco_subscription_id']
    assert_equal 'existing-org', projected.dig('postiz', 'organization_id')
    assert_equal attrs['unrelated'], projected['unrelated']
    account = Account.new(attrs, {})
    Entitlements.apply!(account, contract, subscription_id: 'sub_next')
    assert_equal projected, account.internal_attributes
  end

  def test_new_plan_and_renamed_terms_need_no_plan_branch
    changed = data
    new_plan = Marshal.load(Marshal.dump(changed['plans']['light']['versions'].values.first))
    new_plan['sellable'] = true
    new_plan['name'] = 'テスト店舗プラン'
    new_plan['entitlements']['limits']['agents'] = 8
    changed['plans']['seasonal'] = { 'versions' => { 'test-v2' => new_plan } }
    changed['current_versions']['seasonal'] = 'test-v2'
    catalog = Catalog.new(changed)

    contract = snapshot('seasonal', catalog: catalog)
    account = Account.new({}, {})
    Entitlements.apply!(account, contract, catalog: catalog)
    assert_equal 'テスト店舗プラン', Entitlements.contract_for(account)['name']
    assert_equal 8, Toybaco::AgentSeatLimit.limit_for(account)
    assert_equal false, account.internal_attributes.dig('postiz', 'enabled')
  end

  def test_new_sales_version_cannot_change_existing_snapshot
    purchased = purchased()
    changed = data
    future = Marshal.load(Marshal.dump(changed['plans']['light']['versions'].values.first))
    future['sellable'] = true
    future['entitlements']['limits']['agents'] = 1
    future['cycles']['month']['amount'] = 19_800
    changed['plans']['light']['versions']['future-v2'] = future
    changed['current_versions']['light'] = 'future-v2'
    catalog = Catalog.new(changed)
    account = Account.new({ 'toybaco_contract' => purchased }, {})

    assert_equal 3, Entitlements.for_account(account, catalog: catalog).dig('limits', 'agents')
    assert_equal 1, catalog.sale('light', 'month').dig('entitlements', 'limits', 'agents')
    assert_equal '2026-09-06.1', Entitlements.contract_for(account, catalog: catalog)['plan_version']
    assert_raises(Catalog::Invalid) { catalog.sale('light', 'month', version: purchased['plan_version']) }
  end

  def test_unversioned_legacy_is_not_upgraded_to_current_terms
    account = Account.new({ 'toybaco_plan' => 'starter', 'postiz' => { 'enabled' => true, 'organization_id' => 'keep' } }, {})
    contract = Entitlements.contract_for(account)
    assert_equal 'legacy-unversioned', contract['plan_version']
    assert_nil contract['cycle']
    assert_equal 'starter', contract['plan_id']
    assert_equal 'legacy_manual', contract.dig('addons', 0, 'source')
    assert_equal true, Entitlements.for_account(account).dig('features', 'posting')
    assert_nil Entitlements.for_account(account).dig('features', 'ai_reply')
  end

  def test_explicit_downgrade_revokes_posting_but_preserves_other_attributes
    account = Account.new({ 'postiz' => { 'enabled' => true, 'organization_id' => 'keep' }, 'custom' => 'untouched' }, {})
    Entitlements.apply!(account, purchased('standard'))
    Entitlements.apply!(account, purchased('light'))
    assert_equal false, account.internal_attributes.dig('postiz', 'enabled')
    assert_equal 'keep', account.internal_attributes.dig('postiz', 'organization_id')
    assert_equal 'untouched', account.internal_attributes['custom']
    assert_equal false, account.features['channel_instagram']
  end

  def test_explicit_manual_addon_survives_downgrade
    contract = purchased('light').merge('addons' => [{ 'id' => 'manual-posting', 'quantity' => 1, 'source' => 'manual' }])
    account = Account.new({}, {})
    Entitlements.apply!(account, contract)
    assert_equal true, account.internal_attributes.dig('postiz', 'enabled')
    assert_equal 'manual', account.internal_attributes.dig('toybaco_contract_addons', 0, 'source')
  end

  def test_saved_addon_terms_survive_new_version_or_catalog_removal
    addon = Entitlements.new_addon('manual-posting', quantity: 1, source: 'manual')
    contract = purchased.merge('addons' => [addon])
    changed = data
    changed['addons'].delete('manual-posting')
    catalog = Catalog.new(changed)
    assert_equal true, Entitlements.effective(contract, catalog: catalog).dig('features', 'posting')
    assert_equal '2026-09-06.1', contract.dig('addons', 0, 'version')
  end

  def test_legacy_addon_uses_the_legacy_version_instead_of_new_sales
    changed = data
    changed['addons']['manual-posting']['versions']['v2'] = { 'scope' => 'account', 'features' => { 'posting' => false } }
    changed['addons']['manual-posting']['current_version'] = 'v2'
    catalog = Catalog.new(changed)
    contract = purchased.merge('addons' => [{ 'id' => 'manual-posting', 'quantity' => 1, 'source' => 'legacy_manual' }])
    assert_equal true, Entitlements.effective(contract, catalog: catalog).dig('features', 'posting')
    assert_equal false, Entitlements.new_addon('manual-posting', quantity: 1, source: 'manual', catalog: catalog).dig('terms', 'features', 'posting')
  end

  def test_unknown_version_rejects_new_contract_and_preserves_valid_saved_snapshot
    assert_raises(Catalog::Invalid) { Catalog.default.definition('light', 'missing') }
    account = Account.new({ 'toybaco_plan' => 'light', 'toybaco_plan_version' => 'missing' }, {})
    assert_raises(Catalog::Invalid) { Entitlements.contract_for(account) }
    assert_equal 0, Toybaco::AgentSeatLimit.limit_for(account)
    account.internal_attributes['toybaco_contract'] = purchased
    assert_equal 3, Toybaco::AgentSeatLimit.limit_for(account)
  end

  def test_invalid_price_reference_and_limit_are_rejected
    changed = data
    changed['plans']['light']['versions'].values.first['cycles']['month']['stripe'].delete('test')
    assert_raises(Catalog::Invalid) { Catalog.new(changed) }
    changed = data
    changed['plans']['light']['versions'].values.first['entitlements']['limits']['agents'] = -1
    assert_raises(Catalog::Invalid) { Catalog.new(changed) }
  end

  def test_checkout_metadata_tracks_the_exact_version_and_reference_price
    terms = Catalog.default.sale('pro', 'year')
    params = Toybaco::Checkout.session_params(
      plan: 'pro', cycle: 'year', price: {
        'id' => 'price_ref1', 'unit_amount' => terms.dig('cycles', 'year', 'amount'),
        'currency' => 'jpy', 'active' => true, 'tax_behavior' => 'exclusive',
        'billing_scheme' => 'per_unit', 'transform_quantity' => nil,
        'recurring' => { 'interval' => 'year', 'interval_count' => 1, 'usage_type' => 'licensed' },
        'metadata' => { 'toybaco_plan' => 'pro', 'toybaco_plan_version' => terms['plan_version'] },
        'product' => { 'id' => 'prod_fixture', 'active' => true, 'name' => terms['product_name'], 'description' => terms['description'] }
      }, customer_id: 'cus_test1', success_url: 'https://toybaco.jp/welcome/', cancel_url: 'https://toybaco.jp/signup/'
    )
    assert_equal terms['plan_version'], params['metadata[toybaco_plan_version]']
    assert_equal terms['plan_version'], params['subscription_data[metadata][toybaco_plan_version]']
    assert_equal 'price_ref1', params['metadata[toybaco_reference_price_id]']
    assert_equal 'year', params['metadata[toybaco_cycle]']
    assert_equal 'price_ref1', params['line_items[0][price]']
    refute params.keys.any? { |key| key.include?('[price_data]') }
  end

  def test_price_amount_and_cycle_mismatch_stop_before_checkout
    terms = Catalog.default.sale('light', 'month')
    price = { 'id' => 'price_test1', 'unit_amount' => 1, 'currency' => 'jpy', 'recurring' => { 'interval' => 'month' } }
    assert_raises(Toybaco::Checkout::Unavailable) { Toybaco::Checkout.assert_catalog_price!(price, terms, 'month') }
    price['unit_amount'] = terms.dig('cycles', 'month', 'amount')
    price['recurring']['interval'] = 'year'
    assert_raises(Toybaco::Checkout::NonJpyPrice) { Toybaco::Checkout.assert_catalog_price!(price, terms, 'month') }
  end

  def change_plan(id, cycle = 'month', version = '2026-09-06.1')
    { plan_id: id, plan_version: version, cycle: cycle }
  end

  def test_all_explicit_plan_and_cycle_changes_use_the_declared_policy
    catalog = Catalog.new(before_switch_data)
    catalog.sales.product(catalog.sales, Catalog::CYCLES, Catalog::CYCLES).each do |source, target, from_cycle, to_cycle|
      from = change_plan(source['plan_id'], from_cycle)
      to = change_plan(target['plan_id'], to_cycle)
      if from == to
        assert_raises(Catalog::Invalid) { catalog.change_policy(from: from, to: to) }
        next
      end
      kind = from_cycle == to_cycle ? data.dig('plan_changes', 'same_cycle', source['plan_id'], target['plan_id']) : 'cycle_change'
      expected = data.dig('plan_changes', 'policies', kind).merge('kind' => kind, 'version' => '2026-09-06.1')
      assert_equal expected, catalog.change_policy(from: from, to: to)
    end
  end

  def test_transition_direction_never_uses_plan_names_or_prices
    changed = before_switch_data
    light = changed['plans']['light']['versions']['2026-09-06.1']
    light['name'] = '最上位のように見える名前'
    light['cycles']['month']['amount'] = 99_800
    policy = Catalog.new(changed).change_policy(from: change_plan('light'), to: change_plan('pro'))
    assert_equal 'upgrade', policy['kind']
    assert_equal 'after_payment', policy['effective']
    assert_equal 'invoice_difference', policy['proration']
  end

  def test_unlisted_pair_legacy_unknown_version_and_cycle_are_rejected
    changed = data
    changed['plan_changes']['same_cycle']['light'].delete('pro')
    catalog = Catalog.new(changed)
    %w[month year].each do |cycle|
      assert_raises(Catalog::Invalid) { catalog.change_policy(from: change_plan('light'), to: change_plan('pro', cycle)) }
    end
    [change_plan('starter', 'month', 'legacy-unversioned'), change_plan('light', 'month', 'missing'),
     change_plan('light', 'week'), { plan_id: 'light' }].each do |source|
      assert_raises(Catalog::Invalid) { catalog.change_policy(from: source, to: change_plan('standard')) }
    end
  end

  def test_policy_revision_does_not_rewrite_purchased_snapshot_or_addons
    purchased = purchased().merge('addons' => [Entitlements.new_addon('manual-posting', quantity: 1, source: 'manual')])
    before = Marshal.load(Marshal.dump(purchased))
    changed = before_switch_data
    changed['plan_changes']['version'] = 'future-policy'
    changed['plan_changes']['policies']['upgrade'] = { 'effective' => 'period_end', 'proration' => 'none' }
    catalog = Catalog.new(changed)
    account = Account.new({ 'toybaco_contract' => purchased }, {})
    policy = catalog.change_policy(from: change_plan('light'), to: change_plan('standard'))
    assert_equal 'future-policy', policy['version']
    assert_equal 'period_end', policy['effective']
    assert_equal before, Entitlements.contract_for(account, catalog: catalog)
    assert_equal true, Entitlements.for_account(account, catalog: catalog).dig('features', 'posting')
  end

  def test_sales_switch_sells_the_growth_version_and_keeps_the_former_version_for_contracts
    catalog = Catalog.default
    assert_equal [[CURRENT, 9800], [CURRENT, 19_800], [CURRENT, 29_800]],
                 catalog.sales.map { |plan| [plan['plan_version'], plan.dig('cycles', 'month', 'amount')] }
    assert_equal CURRENT, catalog.data.fetch('free_registration_version')
    refute_includes catalog.data.fetch('current_versions').keys, 'free'
    %w[light standard pro].each do |id|
      %w[month year].each do |cycle|
        assert_equal CURRENT, catalog.sale(id, cycle)['plan_version']
        assert_raises(Catalog::Invalid) { catalog.sale(id, cycle, version: FORMER) }
      end
      former = catalog.definition(id, FORMER)
      assert_equal false, former['sellable'], id
      assert_equal({ 'light' => 9800, 'standard' => 29_800, 'pro' => 44_800 }.fetch(id), former.dig('cycles', 'month', 'amount'))
    end
    account = Account.new({ 'toybaco_contract' => purchased('pro') }, {})
    assert_equal [FORMER, 500], [Entitlements.contract_for(account)['plan_version'], Entitlements.for_account(account).dig('limits', 'ai_replies')]
  end

  def test_only_one_version_of_each_plan_is_sellable
    data = Catalog.default.data
    current = data.fetch('current_versions').merge('free' => data.fetch('free_registration_version'))
    sellable = data.fetch('plans').flat_map do |id, plan|
      plan.fetch('versions').filter_map { |version, terms| [id, version] unless terms['sellable'] == false }
    end
    assert_equal current.to_a.sort, sellable.sort
  end

  def test_a_current_free_version_is_rejected_when_the_catalog_loads
    # Free opens by free_registration_version; as a current sale it would have no billing cycle to sell.
    changed = data
    changed['current_versions']['free'] = changed.fetch('free_registration_version')
    assert_equal 'current plan is not sellable', assert_raises(Catalog::Invalid) { Catalog.new(changed) }.message
  end

  def test_self_service_plan_changes_are_closed_while_no_eligible_version_is_on_sale
    # plan_changes.eligible_versions stays FORMER at the sales switch; the growth versions become eligible in their
    # own slice. A change needs a target that is both eligible and the current sale, so none is offered meanwhile.
    catalog = Catalog.default
    assert_equal %w[light standard pro].to_h { |id| [id, FORMER] }, catalog.data.dig('plan_changes', 'eligible_versions')
    [FORMER, CURRENT].repeated_permutation(2).each do |from_version, to_version|
      %w[light standard pro].permutation(2).each do |from, to|
        assert_raises(Catalog::Invalid) do
          catalog.change_policy(from: change_plan(from, 'month', from_version), to: change_plan(to, 'month', to_version))
        end
      end
    end
    assert_equal 'upgrade', Catalog.new(before_switch_data).change_policy(from: change_plan('light'), to: change_plan('pro'))['kind']
  end

  def test_invalid_declared_transitions_and_policy_combinations_are_rejected
    changed = data
    changed['plan_changes']['same_cycle']['light']['unknown'] = 'upgrade'
    assert_raises(Catalog::Invalid) { Catalog.new(changed) }
    changed = data
    changed['plan_changes']['policies']['upgrade']['proration'] = 'none'
    assert_raises(Catalog::Invalid) { Catalog.new(changed) }
  end
end
