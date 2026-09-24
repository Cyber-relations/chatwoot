# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../overlay/app/lib/toybaco/growth/retention_plan'

class ToybacoGrowthRetentionPlanTest < Minitest::Test
  Plan = Toybaco::Growth::RetentionPlan

  def setup
    @inventory = {
      'inboxes' => [connection('3', 3), connection('2', 2), connection('1', 1)],
      'posting_accounts' => [connection('b', 2), connection('a', 1)],
      'posts' => [post('late', 'a', 20), post('early', 'a', 10), post('other', 'b', 5)]
    }
    @limits = { 'inboxes' => 2, 'posting_accounts' => 1, 'scheduled_posts_per_account' => 1 }
  end

  def connection(id, created)
    { 'id' => id, 'created_at_us' => created }
  end

  def post(id, integration, at, held: false)
    { 'id' => id, 'integration_id' => integration, 'publish_at_us' => at, 'held' => held }
  end

  def plan(**options)
    Plan.new(inventory: @inventory, limits: @limits, **options).read
  end

  def test_defaults_use_creation_order_and_nearest_reservation
    value = plan
    assert_equal %w[1 2], value.dig('inboxes', 'keep')
    assert_equal ['3'], value.dig('inboxes', 'hold')
    assert_equal ['a'], value.dig('posting_accounts', 'keep')
    assert_equal ['early'], value.dig('posts', 'keep')
    assert_equal %w[other late], value.dig('posts', 'hold')
  end

  def test_primary_and_explicit_selection_take_priority
    assert_equal ['b'], plan(primary: { 'posting_accounts' => 'b' }).dig('posting_accounts', 'keep')
    value = plan(primary: { 'posting_accounts' => 'a' }, selected: { 'posting_accounts' => ['b'] })
    assert_equal ['other'], value.dig('posts', 'keep')
    assert_equal %w[early late], value.dig('posts', 'hold')
  end

  def test_explicit_empty_selection_does_not_restore_connections
    value = plan(selected: { 'inboxes' => [], 'posting_accounts' => [] })
    assert_empty value.dig('inboxes', 'keep')
    assert_empty value.dig('posts', 'keep')
    assert_equal 3, value.dig('posts', 'hold').size
  end

  def test_existing_holds_do_not_resume_or_consume_capacity_after_upgrade
    @limits['posting_accounts'] = 2
    @limits['scheduled_posts_per_account'] = 300
    @inventory['posts'] << post('held', 'a', 1, held: true)
    result = plan.fetch('posts')
    assert_equal ['held'], result.fetch('already_held')
    assert_equal %w[other early late], result.fetch('keep')
    assert_empty result.fetch('hold')
  end

  def test_cap_applies_per_retained_posting_account
    @limits['posting_accounts'] = 2
    assert_equal %w[other early], plan.dig('posts', 'keep')
    assert_equal ['late'], plan.dig('posts', 'hold')
  end

  def test_ties_are_deterministic_and_input_not_mutated
    @inventory['posts'] << post('earlier_id', 'a', 10)
    before = Marshal.dump(@inventory)
    assert_equal ['earlier_id'], plan.dig('posts', 'keep')
    @inventory['posts'].reverse!
    assert_equal ['earlier_id'], plan.dig('posts', 'keep')
    @inventory['posts'].reverse!
    assert_equal before, Marshal.dump(@inventory)
  end

  def test_zero_limits_hold_all_active_items
    @limits.transform_values! { 0 }
    result = plan
    assert_empty result.dig('posting_accounts', 'keep')
    assert_equal 3, result.dig('posts', 'hold').size
  end

  def test_foreign_duplicate_missing_or_over_limit_selection_is_rejected
    [{ 'inboxes' => ['foreign'] }, { 'inboxes' => %w[1 1] }, { 'inboxes' => %w[1 2 3] },
     { 'posting_accounts' => nil }, { 'other' => [] }].each do |choice|
      assert_raises(Plan::Invalid) { plan(selected: choice) }
    end
    assert_raises(Plan::Invalid) { plan(primary: { 'posting_accounts' => 'foreign' }) }
  end

  def test_ambiguous_or_incomplete_inventory_is_rejected
    @inventory['inboxes'] << connection('1', 10)
    assert_raises(Plan::Invalid) { plan }
    @inventory['inboxes'].pop
    @inventory['posts'] << post('foreign', 'another_store', 2)
    assert_raises(Plan::Invalid) { plan }
    @inventory['posts'].pop
    @inventory['posts'] << post('early', 'a', 2)
    assert_raises(Plan::Invalid) { plan }
  end

  def test_unknown_hold_state_and_unbounded_limits_are_rejected
    @inventory['posts'].first['held'] = nil
    assert_raises(Plan::Invalid) { plan }
    @inventory['posts'].first['held'] = false
    @limits['scheduled_posts_per_account'] = nil
    assert_raises(Plan::Invalid) { plan }
  end

  def test_invalid_times_and_untrusted_identifier_are_rejected
    @inventory['inboxes'].first['created_at_us'] = 'yesterday'
    assert_raises(Plan::Invalid) { plan }
    @inventory['inboxes'].first['created_at_us'] = 1
    @inventory['posts'].first['id'] = '<script>'
    assert_raises(Plan::Invalid) { plan }
  end

  def test_subsecond_order_precedes_identifier_order
    @inventory['posting_accounts'] = [connection('a', 1_000_002), connection('z', 1_000_001)]
    @inventory['posts'] = [post('a_later', 'z', 2_000_002), post('z_earlier', 'z', 2_000_001)]
    result = plan
    assert_equal ['z'], result.dig('posting_accounts', 'keep')
    assert_equal ['z_earlier'], result.dig('posts', 'keep')
  end
end
