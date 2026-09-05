# frozen_string_literal: true

require 'minitest/autorun'
require 'monitor'
require_relative '../overlay/app/lib/toybaco/subscription_sync'

class ToybacoSubscriptionSyncTest < Minitest::Test
  class Account
    attr_accessor :internal_attributes, :status, :features
    attr_reader :lock
    def initialize(contract)
      @internal_attributes = { 'toybaco_contract' => contract, 'toybaco_subscription_id' => 'sub_fixture',
                               'postiz' => { 'enabled' => true, 'organization_id' => 'keep' } }
      @features = {}
      @status = 'active'
      @lock = Monitor.new
    end
    def with_lock(&block) = lock.synchronize(&block)
    def active? = status == 'active'
    def enable_features!(name) = features[name] = true
    def disable_features!(name) = features[name] = false
    def update!(attrs) = attrs.each { |key, value| public_send("#{key}=", value) }
  end

  def contract(plan = 'standard')
    terms = Toybaco::PlanCatalog.default.sale(plan, 'month')
    Toybaco::Entitlements.snapshot_for(terms, cycle: 'month')
  end

  def subscription(plan: 'standard', status: 'active', price_id: 'price_standard')
    terms = Toybaco::PlanCatalog.default.sale(plan, 'month')
    { 'id' => 'sub_fixture', 'status' => status, 'cancel_at_period_end' => false,
      'items' => { 'data' => [{ 'id' => 'si_fixture', 'quantity' => 1, 'price' => {
        'id' => price_id, 'currency' => 'jpy', 'unit_amount' => terms.dig('cycles', 'month', 'amount'),
        'recurring' => { 'interval' => 'month', 'interval_count' => 1 },
        'product' => { 'metadata' => { 'toybaco_plan' => plan, 'toybaco_plan_version' => terms['plan_version'] } }
      } }] } }
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
