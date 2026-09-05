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

  def data
    JSON.parse(File.read(Catalog::PATH))
  end

  def snapshot(id = 'light', catalog: Catalog.default, cycle: 'month')
    Entitlements.snapshot_for(catalog.sale(id, cycle), cycle: cycle)
  end

  def test_new_plan_and_renamed_terms_need_no_plan_branch
    changed = data
    new_plan = Marshal.load(Marshal.dump(changed['plans']['light']['versions'].values.first))
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
    purchased = snapshot
    changed = data
    future = Marshal.load(Marshal.dump(changed['plans']['light']['versions'].values.first))
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
    Entitlements.apply!(account, snapshot('standard'))
    Entitlements.apply!(account, snapshot('light'))
    assert_equal false, account.internal_attributes.dig('postiz', 'enabled')
    assert_equal 'keep', account.internal_attributes.dig('postiz', 'organization_id')
    assert_equal 'untouched', account.internal_attributes['custom']
    assert_equal false, account.features['channel_instagram']
  end

  def test_explicit_manual_addon_survives_downgrade
    contract = snapshot('light').merge('addons' => [{ 'id' => 'manual-posting', 'quantity' => 1, 'source' => 'manual' }])
    account = Account.new({}, {})
    Entitlements.apply!(account, contract)
    assert_equal true, account.internal_attributes.dig('postiz', 'enabled')
    assert_equal 'manual', account.internal_attributes.dig('toybaco_contract_addons', 0, 'source')
  end

  def test_saved_addon_terms_survive_new_version_or_catalog_removal
    addon = Entitlements.new_addon('manual-posting', quantity: 1, source: 'manual')
    contract = snapshot.merge('addons' => [addon])
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
    contract = snapshot.merge('addons' => [{ 'id' => 'manual-posting', 'quantity' => 1, 'source' => 'legacy_manual' }])
    assert_equal true, Entitlements.effective(contract, catalog: catalog).dig('features', 'posting')
    assert_equal false, Entitlements.new_addon('manual-posting', quantity: 1, source: 'manual', catalog: catalog).dig('terms', 'features', 'posting')
  end

  def test_unknown_version_rejects_new_contract_and_preserves_valid_saved_snapshot
    assert_raises(Catalog::Invalid) { Catalog.default.definition('light', 'missing') }
    account = Account.new({ 'toybaco_plan' => 'light', 'toybaco_plan_version' => 'missing' }, {})
    assert_raises(Catalog::Invalid) { Entitlements.contract_for(account) }
    assert_equal 0, Toybaco::AgentSeatLimit.limit_for(account)
    account.internal_attributes['toybaco_contract'] = snapshot
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
end
