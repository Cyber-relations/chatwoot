# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../overlay/app/lib/toybaco/store_fulfillment'

class ToybacoStoreFulfillmentTest < Minitest::Test
  Store = Toybaco::StoreFulfillment
  Account = Struct.new(:id, :internal_attributes, :status) do
    def active? = status == 'active'
    def update!(values) = values.each { |key, value| public_send("#{key}=", value) }
  end

  def setup
    @catalog = Toybaco::PlanCatalog.default
    @addon = Toybaco::Entitlements.new_addon('opt-store', quantity: 1, source: 'stripe').merge(
      'stripe_price_id' => 'price_store', 'subscription_item_id' => 'si_store'
    )
    @item = { 'id' => 'si_store', 'quantity' => 1, 'price' => {
      'id' => 'price_store', 'currency' => 'jpy', 'unit_amount' => 9800,
      'recurring' => { 'interval' => 'month', 'interval_count' => 1 }
    } }
    @line = { 'quantity' => 1, 'amount' => 9800, 'discount_amounts' => [],
              'parent' => { 'subscription_item_details' => { 'subscription' => 'sub_owned', 'subscription_item' => 'si_store', 'proration' => false } },
              'pricing' => { 'price_details' => { 'price' => 'price_store' } } }
    @subscription = { 'id' => 'sub_owned', 'status' => 'active', 'items' => { 'data' => [@item], 'has_more' => false },
                      'latest_invoice' => { 'status' => 'paid', 'amount_remaining' => 0, 'amount_paid' => 60060,
                                            'currency' => 'jpy', 'lines' => { 'has_more' => false, 'data' => [@line] } } }
    @parent = Account.new(1, { 'toybaco_subscription_id' => 'sub_owned' }, 'active')
    @contract = Store.child_contract(@addon, @item)
    @child = Account.new(2, { 'toybaco_contract' => @contract }, 'active')
    @binding = Store.purchase_binding(@parent, @child, { administrator_id: 3 }, { addon: @addon, item: @item, contract: @contract })
    @child.internal_attributes[Store::PURCHASE] = @binding
    @parent.internal_attributes[Store::REGISTRY] = { 'si_store:1' => @binding }
  end

  def paid? = Store.paid_item?(@subscription, 'si_store', 'price_store', 9800)
  def state(outcome = 'applied') = Store.desired_state(@parent, @subscription, @binding, outcome)

  def test_current_addon_issues_only_its_fixed_light_contract
    assert_equal %w[light 2026-09-06.1 month], @contract.values_at('plan_id', 'plan_version', 'cycle')
    assert_equal 3, @contract.dig('entitlements', 'limits', 'agents')
    assert_equal false, @contract.dig('entitlements', 'features', 'posting')
    assert_equal false, @contract.dig('entitlements', 'features', 'ai_reply')
    assert_empty @contract['addons']
  end

  def test_future_catalog_target_needs_no_plan_name_branch
    data = Marshal.load(Marshal.dump(@catalog.data))
    terms = Marshal.load(Marshal.dump(data['plans']['light']['versions']['2026-09-06.1']))
    terms['name'] = '店舗用の新名称'
    terms['entitlements']['limits']['agents'] = 4
    data['plans']['store-next'] = { 'versions' => { 'v2' => terms } }
    @addon['terms'] = @addon['terms'].merge('plan_id' => 'store-next', 'plan_version' => 'v2')
    changed = Store.child_contract(@addon, @item, catalog: Toybaco::PlanCatalog.new(data))
    assert_equal %w[store-next v2 店舗用の新名称], changed.values_at('plan_id', 'plan_version', 'name')
    assert_equal 4, changed.dig('entitlements', 'limits', 'agents')
    assert_equal 'light', @binding.dig('contract', 'plan_id')
  end

  def test_exact_paid_item_is_required_even_with_an_earlier_paid_base_invoice
    assert paid?
    @line['parent']['subscription_item_details']['subscription_item'] = 'si_base'
    refute paid?
  end

  def test_proration_credit_cannot_be_filtered_out_of_paid_item_set
    credit = Marshal.load(Marshal.dump(@line))
    credit['amount'] = -9800
    credit['parent']['subscription_item_details']['proration'] = true
    @subscription['latest_invoice']['lines']['data'] << credit
    refute paid?
  end

  def test_incomplete_unpaid_wrong_owner_and_discounted_invoices_are_not_payment
    original = Marshal.load(Marshal.dump(@subscription))
    changes = [-> { @subscription['latest_invoice']['status'] = 'open' },
               -> { @subscription['latest_invoice']['lines']['has_more'] = true },
               -> { @subscription['latest_invoice']['lines']['data'][0]['discount_amounts'] = [{ 'amount' => 1 }] },
               -> { @subscription['latest_invoice']['lines']['data'][0]['parent']['subscription_item_details']['subscription'] = 'sub_other' },
               -> { @subscription['latest_invoice']['lines']['data'][0]['pricing']['price_details']['price'] = 'price_other' }]
    changes.each do |change|
      @subscription = Marshal.load(Marshal.dump(original))
      change.call
      refute paid?
    end
  end

  def test_period_end_notice_keeps_access_but_parent_stop_and_item_removal_stop_it
    @subscription['cancel_at_period_end'] = true
    assert_equal 'active', state
    @parent.status = 'suspended'
    assert_equal 'parent_suspended', state
    @parent.status = 'active'
    @subscription['items']['data'] = []
    assert_equal 'item_removed', state('needs_review')
  end

  def test_partial_items_cannot_prove_removal_but_parent_stop_still_applies
    @subscription['items'] = { 'data' => [], 'has_more' => true }
    assert_equal 'review', state
    @parent.status = 'suspended'
    assert_equal 'parent_suspended', state
  end

  def test_bad_quantity_stops_existing_store_and_never_chooses_a_first_slot
    [0, 2, 1.5, '1'].each do |quantity|
      @item['quantity'] = quantity
      assert_equal 'invalid_quantity', state('needs_review')
      assert_raises(Store::Unavailable) { Store.subscription_item(@subscription, 'si_store') }
    end
  end

  def test_owned_suspension_resumes_same_snapshot_and_manual_addons
    addon = Toybaco::Entitlements.new_addon('manual-posting', quantity: 1, source: 'manual')
    @child.internal_attributes['toybaco_contract'] = @contract.merge('addons' => [addon])
    saved = Marshal.load(Marshal.dump(@child.internal_attributes['toybaco_contract']))
    Store.update_child_state(@child, 'parent_suspended')
    assert_equal 'suspended', @child.status
    Store.validate_child!(@child, @binding)
    Store.update_child_state(@child, 'active')
    assert_equal 'active', @child.status
    assert_equal saved, @child.internal_attributes['toybaco_contract']
    assert_nil @child.internal_attributes['toybaco_subscription_id']
  end

  def test_manual_suspension_is_not_owned_or_resumed_by_billing
    @child.status = 'suspended'
    Store.update_child_state(@child, 'parent_suspended')
    Store.update_child_state(@child, 'active')
    assert_equal 'suspended', @child.status
    refute @child.internal_attributes[Store::SUSPENDED]
  end

  def test_broken_reciprocal_binding_does_not_mutate_foreign_child_or_rollback_parent_stop
    @parent.status = 'suspended'
    @child.internal_attributes.delete(Store::PURCHASE)
    before = Marshal.load(Marshal.dump(@child.internal_attributes))
    Store.reconcile(@parent, { 2 => @child }, @subscription, 'applied')
    assert_equal 'suspended', @parent.status
    assert_equal 'child_binding', @parent.internal_attributes['toybaco_store_review']
    assert_equal before, @child.internal_attributes
    assert_equal 'active', @child.status
  end
end
