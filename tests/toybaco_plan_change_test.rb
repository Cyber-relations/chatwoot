# frozen_string_literal: true

require 'minitest/autorun'
require 'monitor'
require_relative '../overlay/app/lib/toybaco/checkout/plan_change'

class ToybacoPlanChangeTest < Minitest::Test
  CATALOG = Toybaco::PlanCatalog.default
  ENVIRONMENT = { 'TOYBACO_STRIPE_MODE' => 'test' }.freeze
  SYNCHRONIZER = ->(account, &block) { account.with_lock(&block) }
  SERVICE = Toybaco::Checkout::PlanChange

  class Account
    attr_accessor :internal_attributes, :status, :features
    attr_reader :lock, :id
    def initialize(snapshot)
      @id = 41
      @internal_attributes = { 'toybaco_subscription_id' => 'sub_fixture', 'toybaco_contract' => snapshot,
                               'postiz' => { 'enabled' => true, 'organization_id' => 'keep' }, 'unrelated' => 'keep' }
      @features = {}
      @status = 'active'
      @lock = Monitor.new
    end
    def with_lock(&block) = lock.synchronize(&block)
    def active? = status == 'active'
    def enable_features!(name) = features[name] = true
    def disable_features!(name) = features[name] = false
    def update!(attrs) = attrs.each { |key, value| public_send("#{key}=", Marshal.load(Marshal.dump(value))) }
  end

  class Client
    attr_accessor :sub, :schedule, :failure, :pay_immediately, :preview_amount
    attr_reader :calls, :prices
    def initialize(account, sub, prices)
      @account, @sub, @prices = account, sub, prices
      @calls, @replies = [], {}
      @preview_amount = 4321
    end
    def copy(value) = Marshal.load(Marshal.dump(value))
    def retrieve_subscription(_id)
      raise 'read outside account lock' unless @account.lock.mon_owned?
      copy(sub)
    end
    def retrieve_price(id) = copy(prices.find { |price| price['id'] == id })
    def find_price_by_lookup_key(key) = copy(prices.find { |price| price['lookup_key'] == key })
    def preview_plan_change(params)
      @calls << [:preview, copy(params)]
      { 'currency' => 'jpy', 'amount_due' => preview_amount }
    end
    def mutate(action, params, key)
      @calls << [action, copy(params), key]
      return copy(@replies.fetch(key)) if @replies.key?(key)
      raise Toybaco::Checkout::Error, 'stripe failed' if failure == [action, :before]
      result = yield
      @replies[key] = copy(result)
      raise Toybaco::Checkout::Error, 'stripe response lost' if failure == [action, :after]
      copy(result)
    end
    def update_subscription(_id, params, idempotency_key:)
      if params['cancel_at_period_end']
        return mutate(:cancel, params, idempotency_key) do
          sub['cancel_at_period_end'] = true
          sub
        end
      end
      mutate(:upgrade, params, idempotency_key) do
        if pay_immediately
          pay_target(params.dig('items', 0, 'price'))
        else
          sub['pending_update'] = { 'subscription_items' => copy(params['items']), 'expires_at' => 1_800_086_000 }
          sub['latest_invoice'] = invoice('open')
        end
        sub
      end
    end
    def invoice(status)
      { 'id' => 'in_fixture', 'status' => status, 'currency' => 'jpy', 'total' => 4321,
        'amount_paid' => status == 'paid' ? 4321 : 0, 'hosted_invoice_url' => 'https://invoice.stripe.com/i/fixture' }
    end
    def pay_target(price_id)
      sub['items']['data'][0]['price'] = retrieve_price(price_id)
      sub['pending_update'] = nil
      sub['latest_invoice'] = invoice('paid')
      sub
    end
    def create_subscription_schedule(id, idempotency_key:)
      mutate(:create, { 'from_subscription' => id }, idempotency_key) do
        raise 'external schedule overwritten' if sub['schedule']
        item = sub.dig('items', 'data', 0)
        @schedule = {
          'id' => 'sub_sched_fixture', 'subscription' => id, 'status' => 'active', 'metadata' => {}, 'end_behavior' => 'release',
          'default_settings' => { 'automatic_tax' => { 'enabled' => true }, 'default_payment_method' => 'pm_keep' },
          'phases' => [{ 'start_date' => item['current_period_start'], 'end_date' => item['current_period_end'],
                         'items' => [{ 'price' => item.dig('price', 'id'), 'quantity' => 1, 'tax_rates' => [], 'discounts' => [] }],
                         'add_invoice_items' => [], 'discounts' => [],
                         'metadata' => { 'keep' => 'phase-value' }, 'default_tax_rates' => [], 'proration_behavior' => 'create_prorations' }]
        }
        sub['schedule'] = @schedule['id']
        @schedule
      end
    end
    def retrieve_subscription_schedule(_id) = copy(schedule)
    def update_subscription_schedule(_id, params, idempotency_key:)
      mutate(:configure, params, idempotency_key) do
        @schedule.merge!(copy(params.reject { |key, _| key == 'proration_behavior' }))
        @schedule['phases'].each { |phase| phase['add_invoice_items'] ||= [] }
        @schedule
      end
    end
    def release_subscription_schedule(_id, idempotency_key:)
      mutate(:release, { 'preserve_cancel_date' => true }, idempotency_key) do
        @schedule['status'] = 'released'
        @schedule['released_subscription'] = @schedule.delete('subscription')
        sub['schedule'] = nil
        @schedule
      end
    end
  end

  def setup
    @now = 1_800_000_000
    @prices = CATALOG.sales.flat_map do |terms|
      terms.fetch('cycles').map do |cycle, definition|
        { 'id' => "price_#{terms['plan_id']}#{cycle}", 'active' => true, 'livemode' => false, 'currency' => 'jpy',
          'unit_amount' => definition['amount'], 'billing_scheme' => 'per_unit', 'tax_behavior' => 'exclusive',
          'lookup_key' => definition.dig('stripe', 'test', 'lookup_key'),
          'metadata' => { 'toybaco_plan' => terms['plan_id'], 'toybaco_plan_version' => terms['plan_version'] },
          'recurring' => { 'interval' => cycle, 'interval_count' => 1, 'usage_type' => 'licensed' },
          'product' => { 'id' => "prod_#{terms['plan_id']}#{cycle}", 'active' => true,
                         'name' => terms['product_name'], 'description' => terms['description'] } }
      end
    end
    reset_contract
  end

  def reset_contract(plan = 'light', cycle = 'month')
    snapshot = Toybaco::Entitlements.snapshot_for(CATALOG.sale(plan, cycle), cycle: cycle)
    snapshot.merge!('stripe_price_id' => "price_#{plan}#{cycle}", 'subscription_item_id' => 'si_fixture')
    @account = Account.new(snapshot)
    @client = Client.new(@account, {
      'id' => 'sub_fixture', 'customer' => 'cus_fixture', 'status' => 'active', 'livemode' => false,
      'collection_method' => 'charge_automatically', 'cancel_at_period_end' => false, 'schedule' => nil,
      'automatic_tax' => { 'enabled' => true },
      'latest_invoice' => { 'id' => 'in_original', 'status' => 'paid', 'currency' => 'jpy', 'total' => 10780, 'amount_paid' => 10780 },
      'items' => { 'has_more' => false, 'data' => [{ 'id' => 'si_fixture', 'quantity' => 1,
        'current_period_start' => @now - 1000, 'current_period_end' => @now + 2000,
        'price' => @prices.find { |price| price['id'] == "price_#{plan}#{cycle}" } }] }
    }, @prices)
    @service = SERVICE.new(account: @account, client: @client, environment: ENVIRONMENT, synchronizer: SYNCHRONIZER, clock: -> { @now })
  end

  def selection(plan = 'standard', cycle = 'month')
    { 'plan_id' => plan, 'cycle' => cycle, 'plan_version' => CATALOG.data.dig('current_versions', plan) }
  end
  def preview(plan = 'standard', cycle = 'month') = @service.preview(selection(plan, cycle), user_id: 91)
  def commit(quote) = @service.commit(quote, user_id: 91)
  def snapshot = @account.internal_attributes['toybaco_contract']
  def receipt = @account.internal_attributes[SERVICE::RECEIPT_KEY]
  def mutations = @client.calls.reject { |call| call.first == :preview }
  def assert_rejected(code = nil, &block)
    error = assert_raises(Toybaco::Checkout::Error, Toybaco::PlanCatalog::Invalid, &block)
    assert_equal code, error.message if code
  end

  def test_all_six_source_variants_have_five_choices_and_no_mutation
    CATALOG.sales.each do |terms|
      %w[month year].each do |cycle|
        reset_contract(terms['plan_id'], cycle)
        state = @service.state
        assert_equal 'available', state['status']
        assert_equal 5, state['choices'].length
        assert_equal [], mutations
      end
    end
  end

  def test_preview_is_exact_stripe_amount_and_upgrade_replaces_existing_item_only_after_payment
    before = Marshal.load(Marshal.dump(snapshot))
    quote = preview
    assert_equal 4321, quote['amount_due']
    assert_equal 'upgrade', quote.dig('policy', 'kind')
    details = @client.calls.first[1]['subscription_details']
    assert_equal quote['created_at'], details['proration_date']
    assert_equal [{ 'id' => 'si_fixture', 'price' => 'price_standardmonth', 'quantity' => 1 }], details['items']
    assert_equal 'payment_pending', commit(quote)['status']
    assert_equal before, snapshot
    assert_equal 'pending_if_incomplete', mutations.first[1]['payment_behavior']
    assert_equal 'always_invoice', mutations.first[1]['proration_behavior']
    assert_equal details['proration_date'], mutations.first[1]['proration_date']
    assert_equal 'payment_pending', @service.refresh['status']
    assert_equal 1, mutations.length
    @client.pay_target('price_standardmonth')
    assert_equal 'applied', @service.refresh['status']
    assert_equal 'standard', snapshot['plan_id']
    assert_equal 'keep', @account.internal_attributes['unrelated']
    assert_equal 'keep', @account.internal_attributes.dig('postiz', 'organization_id')
    assert_equal 'applied', commit(quote)['status']
    assert_equal 1, mutations.length
  end

  def test_paid_invoice_without_target_price_does_not_grant_upgrade
    quote = preview
    commit(quote)
    @client.sub['latest_invoice']['status'] = 'paid'
    assert_equal 'payment_pending', @service.refresh['status']
    assert_equal 'light', snapshot['plan_id']
    @client.sub['pending_update'] = nil
    assert_equal 'expired', @service.refresh['status']
    assert_equal 'light', snapshot['plan_id']
  end

  def test_immediately_paid_upgrade_and_duplicate_confirmation_charge_once
    @client.pay_immediately = true
    quote = preview('pro')
    assert_equal 'applied', commit(quote)['status']
    assert_equal 'pro', snapshot['plan_id']
    assert_equal 'applied', commit(quote)['status']
    assert_equal 1, mutations.length
  end

  def test_unknown_upgrade_response_keeps_receipt_and_reconciles_without_second_invoice
    quote = preview
    @client.failure = [:upgrade, :after]
    assert_rejected { commit(quote) }
    assert_equal 'requested', receipt['status']
    assert_equal 'light', snapshot['plan_id']
    assert_equal 'payment_pending', @service.refresh['status']
    assert_equal 1, mutations.length
    @client.pay_target('price_standardmonth')
    assert_equal 'applied', @service.refresh['status']
  end

  def test_before_request_failure_replays_identical_idempotency_key_and_parameters
    quote = preview
    @client.failure = [:upgrade, :before]
    assert_rejected { commit(quote) }
    @client.failure = nil
    assert_equal 'payment_pending', @service.refresh['status']
    assert_equal mutations[0], mutations[1]
  end

  def test_every_downgrade_and_cycle_change_is_scheduled_with_current_terms_untouched
    [%w[pro month light month], %w[pro year standard year], %w[light month pro year],
     %w[pro year light month], %w[standard month standard year], %w[standard year standard month]].each do |from, cycle, to, target_cycle|
      reset_contract(from, cycle)
      before = Marshal.load(Marshal.dump(snapshot))
      quote = preview(to, target_cycle)
      assert_nil quote['amount_due']
      state = commit(quote)
      assert_equal 'reserved', state['status']
      assert_equal before, snapshot
      assert_equal [:create, :configure], mutations.map(&:first)
      params = mutations.last[1]
      assert_equal 'none', params['proration_behavior']
      assert_equal 'release', params['end_behavior']
      assert_equal quote['period_end'], params.dig('phases', 0, 'end_date')
      assert_equal quote['period_end'], params.dig('phases', 1, 'start_date')
      assert_equal "price_#{from}#{cycle}", params.dig('phases', 0, 'items', 0, 'price')
      assert_equal "price_#{to}#{target_cycle}", params.dig('phases', 1, 'items', 0, 'price')
      assert_equal to, params.dig('phases', 1, 'metadata', 'toybaco_plan')
      assert_equal CATALOG.data.dig('current_versions', to), params.dig('phases', 1, 'metadata', 'toybaco_plan_version')
      assert_equal 'phase-value', params.dig('phases', 0, 'metadata', 'keep')
      assert_equal 'phase-value', params.dig('phases', 1, 'metadata', 'keep')
      assert_equal true, @client.schedule.dig('default_settings', 'automatic_tax', 'enabled')
      refute_equal mutations[0][2], mutations[1][2]
      assert_equal 'reserved', @service.refresh['status']
      assert_equal 2, mutations.length
    end
  end

  def test_cancel_reservation_releases_schedule_without_cancelling_subscription_or_erasing_snapshot
    before = Marshal.load(Marshal.dump(snapshot))
    state = commit(preview('pro', 'year'))
    assert_rejected('changed') { @service.cancel_reservation('forged') }
    assert_equal 'released', @service.cancel_reservation(state['cancellation_token'])['status']
    assert_equal :release, mutations.last.first
    assert_equal 'active', @client.sub['status']
    assert_equal false, @client.sub['cancel_at_period_end']
    assert_nil @client.sub['schedule']
    assert_equal before, snapshot
    assert_equal 'available', @service.state['status']
  end

  def test_create_and_configure_lost_responses_are_recovered_with_same_keys
    [:create, :configure].each do |action|
      reset_contract
      quote = preview('standard', 'year')
      @client.failure = [action, :after]
      assert_rejected { commit(quote) }
      @client.failure = nil
      assert_equal 'reserved', @service.refresh['status']
      assert_equal 1, mutations.select { |call| call.first == action }.map(&:last).uniq.length
      assert_equal 'light', snapshot['plan_id']
    end
  end

  def test_release_lost_response_is_reconciled_without_second_release
    state = commit(preview('pro', 'year'))
    @client.failure = [:release, :after]
    assert_rejected { @service.cancel_reservation(state['cancellation_token']) }
    assert_equal 'releasing', receipt['status']
    assert_equal 'released', @service.refresh['status']
    assert_equal 1, mutations.count { |call| call.first == :release }
  end

  def test_future_phase_activation_syncs_target_then_releases_own_schedule
    quote = preview('standard', 'year')
    commit(quote)
    @now = quote['period_end']
    @client.pay_target('price_standardyear')
    assert_equal 'effective', @service.state['status']
    assert_equal 'applied', @service.refresh['status']
    assert_equal 'standard', snapshot['plan_id']
    assert_equal 'year', snapshot['cycle']
    assert_nil @client.sub['schedule']
  end

  def test_external_schedule_or_changed_owned_phase_is_never_adopted_updated_or_released
    @client.sub['schedule'] = 'sub_sched_external'
    assert_equal 'unavailable', @service.state['status']
    assert_rejected('schedule_conflict') { preview }
    assert_empty mutations
    @client.sub['schedule'] = nil
    state = commit(preview('standard', 'year'))
    @client.schedule['phases'][1]['items'][0]['quantity'] = 2
    assert_rejected('schedule_conflict') { @service.cancel_reservation(state['cancellation_token']) }
    assert_rejected('schedule_conflict') { @service.refresh }
    assert_equal [:create, :configure], mutations.map(&:first)
  end

  def test_changed_quote_user_account_policy_price_metadata_invoice_or_period_is_rejected_before_mutation
    [->(quote) { quote['user_id'] = 900 }, ->(quote) { quote['account_id'] = 900 },
     ->(_quote) { @client.sub['latest_invoice']['status'] = 'open' },
     ->(_quote) { @now += 3000 }, ->(_quote) { @client.prices[2]['active'] = false },
     ->(_quote) { @client.prices[2]['metadata']['toybaco_plan_version'] = 'unknown' },
     ->(_quote) { @client.sub['items']['data'][0]['quantity'] = 2 },
     ->(_quote) { @client.sub['schedule'] = 'sub_sched_external' }].each do |change|
      setup
      quote = preview
      change.call(quote)
      assert_rejected { commit(quote) }
      assert_empty mutations
      assert_equal 'light', snapshot['plan_id']
    end
  end

  def test_old_catalog_confirmation_cannot_create_new_charge_or_schedule
    quote = preview
    catalog = Object.new
    catalog.define_singleton_method(:definition) { |*args| CATALOG.definition(*args) }
    catalog.define_singleton_method(:sale) { |*args, **kwargs| CATALOG.sale(*args, **kwargs) }
    catalog.define_singleton_method(:change_policy) { |**kwargs| CATALOG.change_policy(**kwargs).merge('version' => 'next') }
    @service = SERVICE.new(account: @account, client: @client, catalog: catalog, environment: ENVIRONMENT, synchronizer: SYNCHRONIZER, clock: -> { @now })
    assert_rejected('changed') { commit(quote) }
    assert_empty mutations
  end

  def test_legacy_manual_addons_multiple_items_and_unpaid_contracts_preserve_rights
    [-> { snapshot['legacy'] = true },
     -> { snapshot['addons'] = [Toybaco::Entitlements.bind_addon({ 'id' => 'manual-posting', 'quantity' => 1 }, catalog: CATALOG)] },
     -> { @client.sub['items']['data'] << Marshal.load(Marshal.dump(@client.sub['items']['data'][0])) },
     -> { @client.sub['latest_invoice']['status'] = 'open' },
     -> { @client.sub['pending_update'] = { 'unknown' => true } },
     -> { @client.sub['cancel_at_period_end'] = true },
     -> { @client.sub['discounts'] = ['di_keep'] }].each do |change|
      setup
      change.call
      before = Marshal.load(Marshal.dump(snapshot))
      assert_rejected { preview }
      assert_equal before, snapshot
      assert_empty mutations
    end
  end

  def test_old_ambiguous_operation_does_not_get_new_idempotency_key
    @client.failure = [:create, :before]
    assert_rejected { commit(preview('pro', 'year')) }
    @client.failure = nil
    @now += 24 * 3600
    assert_rejected('review') { @service.refresh }
    assert_equal 1, mutations.length
  end
  def test_changed_customer_balance_requires_a_new_confirmation_before_any_charge
    quote = preview
    @client.preview_amount += 1
    assert_rejected('changed') { commit(quote) }
    assert_empty mutations
    assert_nil receipt
  end

  def test_activated_release_before_request_failure_retries_with_saved_applied_intent
    quote = preview('standard', 'year')
    commit(quote)
    @now = quote['period_end']
    @client.pay_target('price_standardyear')
    @client.failure = [:release, :before]
    assert_rejected { @service.refresh }
    assert_equal 'applied', receipt['release_result']
    @client.failure = nil
    assert_equal 'applied', @service.refresh['status']
    assert_equal 1, mutations.select { |call| call.first == :release }.map(&:last).uniq.length
  end

  def test_stripe_natural_schedule_completion_can_reconcile_without_releasing_again
    %w[released completed].each do |status|
      reset_contract
      quote = preview('standard', 'year')
      commit(quote)
      @now = @client.schedule['phases'].last['end_date']
      @client.pay_target('price_standardyear')
      @client.sub['schedule'] = nil
      @client.schedule['status'] = status
      @client.schedule['released_subscription'] = @client.schedule.delete('subscription')
      assert_equal 'effective', @service.state['status']
      assert_equal 'applied', @service.refresh['status']
      assert_equal 'standard', snapshot['plan_id']
      refute_includes mutations.map(&:first), :release
    end
  end

  def test_owned_reservation_is_released_and_period_end_cancelled_in_one_confirmation
    before = Marshal.load(Marshal.dump(snapshot))
    state = commit(preview('standard', 'year'))
    assert_rejected('changed') { @service.cancel_subscription }
    result = @service.cancel_subscription(reservation_token: state['cancellation_token'])
    assert_equal({ 'cancelled' => true }, result)
    assert_equal [:create, :configure, :release, :cancel], mutations.map(&:first)
    assert_equal({ 'cancel_at_period_end' => 'true' }, mutations.last[1])
    assert_equal before, snapshot
    assert_nil @client.sub['schedule']
    assert_equal true, @client.sub['cancel_at_period_end']
  end

  def test_combined_cancel_recovers_both_release_and_cancel_failures_without_duplicate_steps
    [[:release, :after], [:cancel, :before], [:cancel, :after]].each do |failure|
      reset_contract
      state = commit(preview('standard', 'year'))
      @client.failure = failure
      assert_rejected { @service.cancel_subscription(reservation_token: state['cancellation_token']) }
      assert_equal 'requested', @account.internal_attributes.dig('toybaco_cancel_request', 'status')
      @client.failure = nil
      assert_equal({ 'cancelled' => true }, @service.cancel_subscription(reservation_token: state['cancellation_token']))
      assert_equal 1, mutations.select { |call| call.first == :release }.map(&:last).uniq.length
      assert_equal 1, mutations.select { |call| call.first == :cancel }.map(&:last).uniq.length
      assert_equal 'complete', @account.internal_attributes.dig('toybaco_cancel_request', 'status')
    end
  end

  def test_external_schedule_and_pending_payment_are_not_cancelled_or_voided
    @client.sub['schedule'] = 'sub_sched_external'
    assert_rejected('schedule_conflict') { @service.cancel_subscription }
    assert_empty mutations
    @client.sub['schedule'] = nil
    quote = preview
    commit(quote)
    assert_rejected('payment_pending') { @service.cancel_subscription }
    assert_equal [:upgrade], mutations.map(&:first)
    assert_equal 'light', snapshot['plan_id']
  end

  def test_old_paginated_subscription_can_cancel_without_changing_items_or_contract
    @client.sub['items']['has_more'] = true
    before = Marshal.load(Marshal.dump(snapshot))
    assert_rejected('unsupported') { preview }
    assert_equal({ 'cancelled' => true }, @service.cancel_subscription)
    assert_equal before, snapshot
    assert_equal [:cancel], mutations.map(&:first)
  end

  def test_rotating_invoice_document_links_do_not_invalidate_a_confirmed_quote
    original_read = @client.method(:retrieve_subscription)
    reads = 0
    @client.define_singleton_method(:retrieve_subscription) do |id|
      value = original_read.call(id)
      reads += 1
      value['latest_invoice'].merge!(
        'hosted_invoice_url' => "https://invoice.stripe.com/i/fixture-link-#{reads}",
        'invoice_pdf' => "https://pay.stripe.com/invoice/fixture-document-#{reads}/pdf"
      )
      value
    end
    before = Marshal.load(Marshal.dump(snapshot))
    quote = preview
    assert_equal 'payment_pending', commit(quote)['status']
    assert_equal before, snapshot
    assert_equal [:upgrade], mutations.map(&:first)
    assert_operator reads, :>, 1
  end

  def test_invoice_financial_and_subscription_conditions_still_invalidate_a_quote
    [->(sub) { sub['latest_invoice']['total'] += 1 },
     ->(sub) { sub['latest_invoice']['amount_paid'] += 1 },
     ->(sub) { sub['latest_invoice']['amount_remaining'] = 1 },
     ->(sub) { sub['latest_invoice']['starting_balance'] = -1 },
     ->(sub) { sub['latest_invoice']['currency'] = 'usd' },
     ->(sub) { sub['latest_invoice']['status'] = 'open' },
     ->(sub) { sub['automatic_tax']['enabled'] = false },
     ->(sub) { sub['cancel_at_period_end'] = true }].each do |change|
      reset_contract
      quote = preview
      before = Marshal.load(Marshal.dump(snapshot))
      change.call(@client.sub)
      assert_rejected { commit(quote) }
      assert_empty mutations
      assert_equal before, snapshot
    end
  end

  def with_http_capture
    requests = []
    response = Net::HTTPOK.new('1.1', '200', 'OK')
    response.body = '{"id":"sub_fixture"}'
    response.instance_variable_set(:@read, true)
    transport = Object.new
    transport.define_singleton_method(:request) { |request| requests << request; response }
    call = ->(*_args, **_kwargs, &block) { block.call(transport) }
    Net::HTTP.stub(:start, call) { yield Toybaco::Checkout::Client.new('fixture-key'), requests }
  end

  def test_stripe_transport_sends_fixed_item_nested_form_and_idempotency_header
    with_http_capture do |client, requests|
      client.update_subscription('sub_fixture', {
        'items' => [{ 'id' => 'si_fixture', 'price' => 'price_proyear', 'quantity' => 1 }],
        'payment_behavior' => 'pending_if_incomplete', 'proration_date' => 1_800_000_000
      }, idempotency_key: 'fixture-upgrade-key')
      request = requests.fetch(0)
      assert_equal '/v1/subscriptions/sub_fixture', request.path
      assert_equal 'fixture-upgrade-key', request['Idempotency-Key']
      assert_equal({ 'items[0][id]' => 'si_fixture', 'items[0][price]' => 'price_proyear', 'items[0][quantity]' => '1',
                     'payment_behavior' => 'pending_if_incomplete', 'proration_date' => '1800000000' }, URI.decode_www_form(request.body).to_h)
    end
  end

  def test_schedule_configuration_omits_empty_extra_invoice_items_but_preserves_explicit_resets
    state = commit(preview('pro', 'year'))
    assert_equal 'reserved', state['status']
    configuration = mutations.last[1]
    with_http_capture do |client, requests|
      client.update_subscription_schedule('sub_sched_fixture', configuration, idempotency_key: 'configure-fixture')
      form = URI.decode_www_form(requests.last.body).to_h
      2.times do |index|
        refute form.key?("phases[#{index}][add_invoice_items]"), 'Stripe does not accept an empty add_invoice_items value'
        assert_equal '', form.fetch("phases[#{index}][discounts]")
        assert_equal '', form.fetch("phases[#{index}][default_tax_rates]")
        assert_equal '', form.fetch("phases[#{index}][items][0][tax_rates]")
        assert_equal '', form.fetch("phases[#{index}][items][0][discounts]")
        assert_equal [], @client.schedule.dig('phases', index, 'add_invoice_items')
      end
    end
    assert_equal 'reserved', @service.refresh['status']
    assert_equal 'released', @service.cancel_reservation(state['cancellation_token'])['status']
    assert_equal 'light', snapshot['plan_id']
  end

  def test_phase_projection_preserves_nonempty_extra_invoice_items_and_does_not_mutate_source
    phase = {
      'items' => [{ 'price' => 'price_lightmonth', 'quantity' => 1, 'tax_rates' => [] }],
      'add_invoice_items' => [{ 'price' => 'price_existing_extra', 'quantity' => 2 }], 'discounts' => []
    }
    before = Marshal.load(Marshal.dump(phase))
    projected = @service.send(:writable_phase, phase)
    assert_equal before, phase
    assert_equal phase['add_invoice_items'], projected['add_invoice_items']
    with_http_capture do |client, requests|
      client.update_subscription_schedule('sub_sched_fixture', { 'phases' => [projected] }, idempotency_key: 'nonempty-fixture')
      form = URI.decode_www_form(requests.last.body).to_h
      assert_equal 'price_existing_extra', form.fetch('phases[0][add_invoice_items][0][price]')
      assert_equal '2', form.fetch('phases[0][add_invoice_items][0][quantity]')
      assert_equal '', form.fetch('phases[0][discounts]')
    end
    phase['add_invoice_items'] = []
    @service.send(:writable_phase, phase)
    assert_equal [], phase.fetch('add_invoice_items')
  end

  def test_schedule_transport_creates_from_subscription_only_and_releases_without_cancel
    with_http_capture do |client, requests|
      client.create_subscription_schedule('sub_fixture', idempotency_key: 'create-fixture')
      assert_equal({ 'from_subscription' => 'sub_fixture' }, URI.decode_www_form(requests.first.body).to_h)
      client.update_subscription_schedule('sub_sched_fixture', {
        'metadata' => { 'toybaco_owner' => 'fixture' }, 'phases' => [{ 'items' => [{ 'price' => 'price_proyear', 'quantity' => 1 }] }]
      }, idempotency_key: 'configure-fixture')
      assert_equal({ 'metadata[toybaco_owner]' => 'fixture', 'phases[0][items][0][price]' => 'price_proyear',
                     'phases[0][items][0][quantity]' => '1' }, URI.decode_www_form(requests.last.body).to_h)
      client.release_subscription_schedule('sub_sched_fixture', idempotency_key: 'release-fixture')
      assert_equal '/v1/subscription_schedules/sub_sched_fixture/release', requests.last.path
      assert_equal({ 'preserve_cancel_date' => 'true' }, URI.decode_www_form(requests.last.body).to_h)
      assert_equal %w[create-fixture configure-fixture release-fixture], requests.map { |request| request['Idempotency-Key'] }
    end
  end

end
