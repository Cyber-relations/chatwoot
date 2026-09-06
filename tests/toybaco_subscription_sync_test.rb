# frozen_string_literal: true

require 'minitest/autorun'
require 'monitor'
require_relative '../overlay/app/lib/toybaco/subscription_sync'
require_relative '../overlay/app/lib/toybaco/agent_seat_limit'
require_relative '../overlay/app/lib/toybaco/ai_usage'

class ToybacoSubscriptionSyncTest < Minitest::Test
  class Account
    attr_accessor :internal_attributes, :status, :features, :account_users
    attr_reader :lock
    def initialize(contract)
      @internal_attributes = { 'toybaco_contract' => contract, 'toybaco_subscription_id' => 'sub_fixture',
                               'postiz' => { 'enabled' => true, 'organization_id' => 'keep' } }
      @features = {}
      @account_users = []
      @status = 'active'
      @lock = Monitor.new
    end
    def with_lock(&block) = lock.synchronize(&block)
    def active? = status == 'active'
    def enable_features!(name) = features[name] = true
    def disable_features!(name) = features[name] = false
    def update!(attrs) = attrs.each { |key, value| public_send("#{key}=", value) }
  end

  Message = Struct.new(:content_attributes) do
    def with_lock = yield
    def update!(content_attributes:) = self.content_attributes = content_attributes
  end

  def contract(plan = 'standard')
    terms = Toybaco::PlanCatalog.default.sale(plan, 'month')
    Toybaco::Entitlements.snapshot_for(terms, cycle: 'month')
  end

  def subscription(plan: 'standard', status: 'active', price_id: 'price_standard', catalog: Toybaco::PlanCatalog.default)
    terms = catalog.sale(plan, 'month')
    { 'id' => 'sub_fixture', 'status' => status, 'cancel_at_period_end' => false,
      'items' => { 'data' => [{ 'id' => 'si_fixture', 'quantity' => 1, 'price' => {
        'id' => price_id, 'currency' => 'jpy', 'unit_amount' => terms.dig('cycles', 'month', 'amount'),
        'recurring' => { 'interval' => 'month', 'interval_count' => 1 },
        'product' => { 'metadata' => { 'toybaco_plan' => plan, 'toybaco_plan_version' => terms['plan_version'] } }
      } }] } }
  end

  def addon_metadata
    { 'toybaco_addon' => 'opt-store',
      'toybaco_addon_version' => Toybaco::PlanCatalog.default.data.dig('addons', 'opt-store', 'current_version') }
  end

  def store_item(metadata: {}, product_metadata: {})
    { 'id' => 'si_store', 'quantity' => 1, 'price' => {
      'id' => 'price_store', 'lookup_key' => 'opt-store', 'currency' => 'jpy', 'unit_amount' => 9800,
      'recurring' => { 'interval' => 'month', 'interval_count' => 1 },
      'metadata' => metadata, 'product' => { 'metadata' => product_metadata }
    } }
  end

  def setup
    @account = Account.new(contract)
    @latest = subscription
    @client = Object.new
    owner = self
    @client.define_singleton_method(:retrieve_subscription) do |_id|
      raise 'Stripe read outside account lock' unless owner.instance_variable_get(:@account).lock.mon_owned?
      Marshal.load(Marshal.dump(owner.instance_variable_get(:@latest)))
    end
    @sync = Toybaco::SubscriptionSync.new(client: @client)
  end

  def sync = @sync.call(@account, subscription_id: 'sub_fixture')
  def stored = @account.internal_attributes['toybaco_contract']

  def test_known_upgrade_then_downgrade_preserves_data_and_applies_exact_terms
    @latest = subscription(plan: 'pro', price_id: 'price_pro')
    assert_equal 'applied', sync
    assert_equal 500, stored.dig('entitlements', 'limits', 'ai_replies')
    @latest = subscription(plan: 'light', price_id: 'price_light')
    sync
    assert_equal 'light', stored['plan_id']
    assert_equal 3, stored.dig('entitlements', 'limits', 'agents')
    assert_equal false, @account.internal_attributes.dig('postiz', 'enabled')
    assert_equal 'keep', @account.internal_attributes.dig('postiz', 'organization_id')
  end

  def test_repeated_or_late_events_always_read_latest_subscription
    sync
    @latest = subscription(plan: 'light', price_id: 'price_light')
    3.times { sync }
    assert_equal 'light', stored['plan_id']
    assert_equal 'price_light', stored['stripe_price_id']
  end

  def test_existing_price_retains_snapshot_even_if_published_catalog_changes
    sync
    data = JSON.parse(File.read(Toybaco::PlanCatalog::PATH))
    data['plans']['standard']['versions'].values.first['entitlements']['limits']['agents'] = 2
    @sync = Toybaco::SubscriptionSync.new(client: @client, catalog: Toybaco::PlanCatalog.new(data))
    sync
    assert_nil stored.dig('entitlements', 'limits', 'agents')
  end

  def test_future_plan_syncs_renamed_terms_and_new_feature_combination_then_keeps_purchased_limits
    data = JSON.parse(File.read(Toybaco::PlanCatalog::PATH))
    future = Marshal.load(Marshal.dump(data['plans']['pro']['versions'].values.first))
    future['name'] = '季節店舗プラン'
    future['entitlements']['features'] = { 'channel_instagram' => false, 'posting' => true, 'ai_reply' => true }
    future['entitlements']['limits'].merge!('agents' => 4, 'ai_replies' => 3)
    data['plans']['seasonal'] = { 'versions' => { 'future-v1' => future } }
    data['current_versions']['seasonal'] = 'future-v1'
    catalog = Toybaco::PlanCatalog.new(data)
    @sync = Toybaco::SubscriptionSync.new(client: @client, catalog: catalog)
    @latest = subscription(plan: 'seasonal', price_id: 'price_seasonal', catalog: catalog)

    assert_equal 'applied', sync
    assert_equal ['seasonal', 'future-v1', '季節店舗プラン'], stored.values_at('plan_id', 'plan_version', 'name')
    assert_equal future['entitlements']['features'], Toybaco::Entitlements.for_account(@account)['features']
    assert_equal false, @account.features['channel_instagram']
    assert_equal true, @account.internal_attributes.dig('postiz', 'enabled')
    [3, 4, 5].each do |count|
      @account.account_users = Array.new(count)
      payload = Toybaco::AgentSeatLimit.payload(@account)
      assert_equal [4, count, count >= 4], payload.values_at('limit', 'count', 'at_limit')
      assert_equal count >= 4, Toybaco::AgentSeatLimit.at_limit?(@account)
      assert_equal '利用は4名まで', payload['title']
    end

    usage = Toybaco::AiUsage.new(@account, now: Time.iso8601('2026-09-10T12:00:00+09:00'))
    3.times do |index|
      message = Message.new({})
      reservation = usage.reserve(message)
      assert_equal 'reserved', reservation['result']
      assert_equal 2 - index, reservation['remaining']
      assert_equal 'consumed', usage.settle(message, token: reservation['token'], outcome: 'consumed')['result']
    end
    assert_equal 'denied', usage.reserve(Message.new({}))['result']
    purchased = Marshal.load(Marshal.dump(stored))

    revised = Marshal.load(Marshal.dump(future))
    revised['name'] = '改定後の店舗プラン'
    revised['entitlements']['features'] = { 'channel_instagram' => true, 'posting' => false, 'ai_reply' => true }
    revised['entitlements']['limits'].merge!('agents' => 1, 'ai_replies' => 1)
    revised['cycles']['month']['amount'] += 1000
    data['plans']['seasonal']['versions']['future-v2'] = revised
    data['current_versions']['seasonal'] = 'future-v2'
    catalog = Toybaco::PlanCatalog.new(data)
    assert_equal revised['name'], catalog.sale('seasonal', 'month')['name']
    @sync = Toybaco::SubscriptionSync.new(client: @client, catalog: catalog)

    assert_equal 'applied', sync
    assert_equal purchased, stored
    assert_equal 4, Toybaco::AgentSeatLimit.limit_for(@account)
    assert_equal false, @account.features['channel_instagram']
    assert_equal true, @account.internal_attributes.dig('postiz', 'enabled')
    assert_equal [3, 3, 0], usage.summary.values_at('limit', 'used', 'remaining')
    assert_equal 'denied', usage.reserve(Message.new({}))['result']
  end

  def test_archived_inline_price_binds_from_product_metadata_without_requiring_new_sale_fields
    price = @latest.dig('items', 'data', 0, 'price')
    price['id'] = 'price_oldinline'
    price['active'] = false
    price['metadata'] = {}
    price['product']['metadata']['toybaco_reference_price_id'] = 'price_oldreference'

    assert_equal 'applied', sync
    assert_equal 'price_oldinline', stored['stripe_price_id']
    assert_equal 'price_oldreference', stored['reference_price_id']
    assert_equal 'standard', stored['plan_id']
  end

  def test_same_inline_price_keeps_snapshot_when_product_display_and_metadata_change
    @latest.dig('items', 'data', 0, 'price')['active'] = false
    sync
    purchased = Marshal.load(Marshal.dump(stored))
    price = @latest.dig('items', 'data', 0, 'price')
    price['product'] = { 'active' => false, 'name' => '過去の商品名', 'description' => '過去の説明',
                         'metadata' => { 'toybaco_plan' => 'pro', 'toybaco_plan_version' => 'unpublished' } }

    assert_equal 'applied', sync
    assert_equal purchased, stored
    refute @account.internal_attributes['toybaco_billing_review']
  end

  def test_explicit_change_from_inline_to_catalog_price_uses_price_metadata_for_new_terms
    @latest.dig('items', 'data', 0, 'price')['active'] = false
    sync
    @latest = subscription(plan: 'pro', price_id: 'price_catalogpro')
    price = @latest.dig('items', 'data', 0, 'price')
    price['active'] = true
    price['metadata'] = price['product']['metadata']
    price['product'] = { 'metadata' => {} }

    assert_equal 'applied', sync
    assert_equal 'pro', stored['plan_id']
    assert_equal Toybaco::PlanCatalog.default.sale('pro', 'month')['plan_version'], stored['plan_version']
    assert_equal 'price_catalogpro', stored['stripe_price_id']
    assert_equal 500, stored.dig('entitlements', 'limits', 'ai_replies')
  end

  def test_base_plan_metadata_is_not_reclassified_by_an_addon_lookup_key
    @latest.dig('items', 'data', 0, 'price')['lookup_key'] = 'opt-store'
    assert_equal 'applied', sync
    assert_equal 'standard', stored['plan_id']
    assert_empty stored['addons']
  end

  def test_known_explicit_addon_metadata_binds_from_price_or_product
    [{ metadata: addon_metadata }, { product_metadata: addon_metadata }].each do |metadata|
      @latest = subscription
      @latest['items']['data'] << store_item(**metadata)
      @account.internal_attributes['toybaco_contract'] = contract
      assert_equal 'applied', sync
      addon = stored['addons'].find { |item| item['source'] == 'stripe' }
      assert_equal 'opt-store', addon['id']
      assert_equal addon_metadata['toybaco_addon_version'], addon['version']
      assert_equal 'separate_account', addon.dig('terms', 'scope')
      assert_equal 'price_store', addon['stripe_price_id']
    end
  end

  def test_invalid_explicit_addon_metadata_preserves_snapshot_manual_store_and_rights
    manual = Toybaco::Entitlements.new_addon('opt-store', quantity: 1, source: 'manual').merge('account_id' => 42)
    @account.internal_attributes['toybaco_contract']['addons'] = [manual]
    sync
    original = Marshal.load(Marshal.dump(stored))
    features = @account.features.dup
    postiz = @account.internal_attributes['postiz'].dup
    invalid = [
      addon_metadata.merge('toybaco_addon' => 'unknown-addon'),
      addon_metadata.merge('toybaco_addon_version' => 'unknown-version'),
      { 'toybaco_addon' => 'opt-store' }, { 'toybaco_addon_version' => addon_metadata['toybaco_addon_version'] },
      addon_metadata.merge('toybaco_addon' => ''), addon_metadata.merge('toybaco_addon_version' => ''),
      addon_metadata.merge('toybaco_addon' => nil), addon_metadata.merge('toybaco_addon_version' => nil),
      addon_metadata.merge('toybaco_addon' => 1), addon_metadata.merge('toybaco_addon_version' => 1),
      addon_metadata.merge('toybaco_addon_version' => ' '), { 'unrelated' => 'not an unversioned price' }
    ]
    invalid.each do |metadata|
      [{ metadata: metadata }, { product_metadata: metadata }].each do |placement|
        @latest = subscription(plan: 'pro', price_id: 'price_newpro')
        @latest['items']['data'] << store_item(**placement)
        assert_equal 'needs_review', sync, metadata.inspect
        assert_equal original, stored
        assert_equal features, @account.features
        assert_equal postiz, @account.internal_attributes['postiz']
        assert @account.active?
        assert_equal true, @account.internal_attributes['toybaco_billing_review']
      end
    end
  end

  def test_unknown_price_addon_version_cannot_fall_back_to_known_product_metadata
    sync
    original = Marshal.load(Marshal.dump(stored))
    @latest['items']['data'] << store_item(
      metadata: { 'toybaco_addon_version' => 'unknown-version' }, product_metadata: addon_metadata
    )
    assert_equal 'needs_review', sync
    assert_equal original, stored
  end

  def test_empty_addon_identifiers_are_rejected_even_if_catalog_has_empty_keys
    data = JSON.parse(File.read(Toybaco::PlanCatalog::PATH))
    data['addons'][''] = { 'versions' => { '' => data['addons']['opt-store']['versions'].values.first } }
    @sync = Toybaco::SubscriptionSync.new(client: @client, catalog: Toybaco::PlanCatalog.new(data))
    original = Marshal.load(Marshal.dump(stored))
    @latest['items']['data'] << store_item(metadata: { 'toybaco_addon' => '', 'toybaco_addon_version' => '' })

    assert_equal 'needs_review', sync
    assert_equal original, stored
  end

  def test_legacy_addon_without_metadata_binds_only_a_unique_lookup_version
    @latest['items']['data'] << store_item(metadata: nil, product_metadata: nil)
    assert_equal 'applied', sync
    assert_equal addon_metadata['toybaco_addon_version'], stored['addons'][0]['version']

    data = JSON.parse(File.read(Toybaco::PlanCatalog::PATH))
    versions = data['addons']['opt-store']['versions']
    versions['ambiguous-version'] = Marshal.load(Marshal.dump(versions.values.first))
    @sync = Toybaco::SubscriptionSync.new(client: @client, catalog: Toybaco::PlanCatalog.new(data))
    @account.internal_attributes['toybaco_contract'] = contract
    original = Marshal.load(Marshal.dump(stored))
    assert_equal 'needs_review', sync
    assert_equal original, stored
  end

  def test_saved_stripe_addon_keeps_terms_after_catalog_removal_and_metadata_change
    @latest['items']['data'] << store_item(metadata: addon_metadata)
    sync
    purchased = Marshal.load(Marshal.dump(stored))
    data = JSON.parse(File.read(Toybaco::PlanCatalog::PATH))
    data['addons'].delete('opt-store')
    @sync = Toybaco::SubscriptionSync.new(client: @client, catalog: Toybaco::PlanCatalog.new(data))
    @latest['items']['data'][1]['price']['metadata'] = addon_metadata.merge('toybaco_addon_version' => 'future-version')

    assert_equal 'applied', sync
    assert_equal purchased, stored
    assert_equal false, @account.internal_attributes['toybaco_billing_review']
  end

  def test_grace_and_period_end_cancellation_preserve_access_until_contract_ends
    @latest['status'] = 'past_due'
    @latest['cancel_at_period_end'] = true
    sync
    assert @account.active?
    assert_equal true, @account.internal_attributes.dig('postiz', 'enabled')
    assert_equal true, @account.internal_attributes['toybaco_cancel_at_period_end']
    @latest['status'] = 'canceled'
    sync
    assert_equal 'suspended', @account.status
    assert_equal false, @account.internal_attributes.dig('postiz', 'enabled')
  end

  def test_paid_restores_only_billing_origin_suspension
    @latest['status'] = 'unpaid'
    sync
    assert_equal 'suspended', @account.status
    @latest['status'] = 'active'
    sync
    assert @account.active?
    assert_equal true, @account.internal_attributes.dig('postiz', 'enabled')
    @account.status = 'suspended'
    sync
    assert_equal 'suspended', @account.status
    refute @account.internal_attributes['toybaco_billing_suspended']
  end

  def test_unknown_price_preserves_old_terms_and_cancellation_still_suspends
    sync
    @latest = subscription(price_id: 'price_unknown')
    @latest.dig('items', 'data', 0, 'price', 'product')['metadata'] = {}
    assert_equal 'needs_review', sync
    assert_equal 'price_standard', stored['stripe_price_id']
    assert_equal true, @account.internal_attributes['toybaco_billing_review']
    @latest['status'] = 'canceled'
    sync
    assert_equal 'suspended', @account.status
  end

  def test_invalid_new_base_price_preserves_snapshot_manual_store_and_effective_rights
    manual = Toybaco::Entitlements.new_addon('opt-store', quantity: 1, source: 'manual').merge('account_id' => 42)
    @account.internal_attributes['toybaco_contract']['addons'] = [manual]
    sync
    purchased = Marshal.load(Marshal.dump(stored))
    features = @account.features.dup
    postiz = @account.internal_attributes['postiz'].dup
    invalid = {
      unknown_version: ->(price) { price['metadata'] = { 'toybaco_plan_version' => 'unpublished' } },
      missing_id: ->(price) { price.delete('id') },
      empty_id: ->(price) { price['id'] = '' },
      wrong_amount: ->(price) { price['unit_amount'] += 1 },
      missing_amount: ->(price) { price.delete('unit_amount') },
      wrong_currency: ->(price) { price['currency'] = 'usd' },
      wrong_cycle: ->(price) { price['recurring']['interval'] = 'year' },
      multiple_intervals: ->(price) { price['recurring']['interval_count'] = 2 }
    }
    invalid.each do |reason, mutate|
      @latest = subscription(plan: 'pro', price_id: 'price_newpro')
      mutate.call(@latest.dig('items', 'data', 0, 'price'))
      assert_equal 'needs_review', sync, reason.to_s
      assert_equal purchased, stored, reason.to_s
      assert_equal features, @account.features, reason.to_s
      assert_equal postiz, @account.internal_attributes['postiz'], reason.to_s
      assert_equal [manual], @account.internal_attributes['toybaco_contract_addons'], reason.to_s
      assert @account.active?, reason.to_s
      assert_equal true, @account.internal_attributes['toybaco_billing_review'], reason.to_s
    end
  end

  def test_incomplete_item_list_does_not_apply_even_a_known_base_price
    sync
    original = Marshal.load(Marshal.dump(@account.internal_attributes))
    features = @account.features.dup
    @latest = subscription(plan: 'pro', price_id: 'price_newpro')
    @latest['items']['has_more'] = true

    assert_raises(Toybaco::SubscriptionSync::Unresolved) { sync }
    assert_equal original, @account.internal_attributes
    assert_equal features, @account.features
    assert @account.active?
  end

  def test_unversioned_first_binding_does_not_promote_legacy_ai_terms
    legacy = Toybaco::PlanCatalog.default.legacy('standard')
    @account.internal_attributes['toybaco_contract'] = Toybaco::Entitlements.snapshot_for(legacy, cycle: nil)
    @latest.dig('items', 'data', 0, 'price', 'product')['metadata'] = {}
    sync
    assert_equal 'legacy-unversioned', stored['plan_version']
    assert_nil stored.dig('entitlements', 'features', 'ai_reply')
  end

  def test_unrelated_subscription_never_mutates_the_account
    original = Marshal.load(Marshal.dump(@account.internal_attributes))
    @latest['id'] = 'sub_other'
    assert_raises(Toybaco::SubscriptionSync::Unresolved) { sync }
    assert_equal original, @account.internal_attributes
    assert_raises(Toybaco::SubscriptionSync::Unresolved) { @sync.call(@account, subscription_id: 'sub_other') }
  end
end
