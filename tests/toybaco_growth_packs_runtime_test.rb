# frozen_string_literal: true

require 'rails/test_help'
require 'minitest/mock'
require 'factory_bot_rails'
require 'ostruct'
require Rails.root.join('lib/toybaco/growth/pack_session')
require Rails.root.join('lib/toybaco/growth/pack_state')
require Rails.root.join('lib/toybaco/growth/pack_fulfillment')
require Rails.root.join('lib/toybaco/growth/pack_refund')

require_relative 'toybaco_growth_pack_stripe_fixture'

FactoryBot.find_definitions unless FactoryBot.factories.registered?(:account)

class ToybacoGrowthPacksRuntimeTest < ActionDispatch::IntegrationTest
  include FactoryBot::Syntax::Methods
  self.use_transactional_tests = true
  Growth = Toybaco::Growth
  NOW = Time.utc(2026, 9, 19, 4)
  VERSION = '2026-09-18.1'
  ENVIRONMENT = { 'TOYBACO_STRIPE_MODE' => 'test', 'TOYBACO_DEPLOYMENT_ENVIRONMENT' => 'staging' }.freeze

  StripeFixture = ToybacoGrowthPackStripeFixture

  def setup
    @previous_pack_secret = ENV['TOYBACO_STRIPE_PACK_WEBHOOK_SECRET']
    ENV['TOYBACO_STRIPE_PACK_WEBHOOK_SECRET'] = 'whsec_fixture12345678901234567890'
    @old_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    travel_to NOW
    data = JSON.parse(File.read(Toybaco::PlanCatalog::PATH))
    data['release_candidates'][VERSION]['ai_pack']['sellable'] = true
    @catalog = Toybaco::PlanCatalog.new(data)
    @client = StripeFixture.new
    @account = create(:account)
    @owner = create(:user, :administrator, account: @account)
    @account.update!(internal_attributes: { Toybaco::BillingAccess::OWNER_KEY => @owner.id, 'toybaco_stripe_customer_id' => 'cus_packstore' })
    set_plan('standard')
    @request_key = SecureRandom.uuid
  end

  def teardown
    @previous_pack_secret ? ENV['TOYBACO_STRIPE_PACK_WEBHOOK_SECRET'] = @previous_pack_secret : ENV.delete('TOYBACO_STRIPE_PACK_WEBHOOK_SECRET')
    travel_back
    ActiveJob::Base.queue_adapter = @old_adapter
    Current.reset
  end

  def set_plan(plan)
    terms = @catalog.definition(plan, VERSION)
    Toybaco::Entitlements.apply!(@account, Toybaco::Entitlements.snapshot_for(terms, cycle: plan == 'free' ? nil : 'month'))
  end

  def enabled(&block)
    Toybaco::PlanCatalog.stub(:default, @catalog, &block)
  end

  def service(key = @request_key)
    Growth::PackSession.new(@account, @owner, client: @client, environment: ENVIRONMENT, request_key: key)
  end

  def start!(key = @request_key)
    service(key).start!('request_key' => key)
  end

  def order(key = @request_key)
    Toybaco::GrowthPackOrder.find_by!(account_id: @account.id, request_key: key)
  end

  def grants
    Toybaco::GrowthAiGrant.where(account_id: @account.id, source: 'pack')
  end

  def complete!(id, event_id)
    Growth::PackFulfillment.new(client: @client).complete!(id, event_id)
  end

  def paid_order
    start!
    id = order.session_id
    [id, @client.pay!(id)]
  end

  def test_catalog_and_current_billing_owner_gate_purchase_before_any_payment_request
    assert_raises(Growth::PurchaseIntent::Unavailable) { start! }
    enabled do
      set_plan('light')
      assert_raises(Growth::PurchaseIntent::Unavailable) { start! }
      set_plan('standard')
      @owner.update!(confirmed_at: nil)
      assert_raises(Growth::PurchaseIntent::Unavailable) { start! }
    end
    assert_empty @client.create_requests
    assert_empty grants
  end

  def test_one_request_survives_lost_response_and_never_creates_a_second_checkout
    enabled do
      @client.fail_after = true
      assert_raises(Toybaco::Checkout::Error) { start! }
      assert_equal 'prepared', order.state
      2.times { assert_equal 'open', start!.fetch('state') }
      assert_equal 1, @client.sessions.length
      assert_equal 1, @client.create_requests.map(&:last).uniq.length
      assert_raises(Growth::PurchaseIntent::Unavailable) { start!(SecureRandom.uuid) }
      assert_empty grants
      form = @client.create_requests.first.first
      assert_equal 'payment', form['mode']
      assert_equal 'card', form['payment_method_types[0]']
      assert_equal 'false', form['allow_promotion_codes']
      assert_equal 'automatic', form['payment_intent_data[capture_method]']
      assert_includes form['success_url'], 'https://app.staging.toybaco.jp/toybaco/growth/packs'
    end
  end

  def test_old_uncertain_request_uses_all_pages_and_does_not_recreate_checkout
    enabled do
      @client.fail_after = true
      assert_raises(Toybaco::Checkout::Error) { start! }
      travel_to NOW + 21.minutes
      @client.incomplete_list = true
      assert_raises(Growth::PurchaseIntent::Unavailable) { service.refresh! }
      assert_equal 'prepared', order.state
      @client.incomplete_list = false
      assert_equal 'open', service.refresh!.fetch('state')
      assert_equal 1, @client.create_requests.length
    end
  end

  def test_payment_success_time_starts_ninety_days_and_duplicate_notifications_do_not_add_units
    enabled do
      start!
      id = order.session_id
      travel_to NOW + 90.seconds
      event_id = @client.pay!(id)
      travel_to NOW + 300.seconds
      2.times { assert_equal 'complete', complete!(id, event_id) }
      assert_equal 1, grants.count
      assert_equal [500, 0], [grants.first.units, grants.first.used]
      assert_equal NOW + 90.seconds, grants.first.starts_at
      assert_equal NOW + 90.seconds + 90.days, grants.first.ends_at
      assert_equal 'complete', start!.fetch('state')
      assert_equal 1, @client.sessions.length
      assert_equal 'complete', service.refresh!.fetch('state')
    end
  end

  def test_plan_change_after_checkout_preserves_paid_pack_for_manual_ai_only
    enabled do
      id, event_id = paid_order
      set_plan('free')
      complete!(id, event_id)
      ledger = Growth::AiLedger.new(@account)
      assert_equal 500, ledger.summary.fetch('remaining')
      assert_equal 0, ledger.summary(kind: 'automatic_reply').fetch('remaining')
      assert_raises(Growth::PurchaseIntent::Unavailable) { start!(SecureRandom.uuid) }
      travel_to NOW + 90.days
      assert_equal 0, Growth::AiLedger.new(@account).summary.fetch('remaining')
    end
  end

  def test_wrong_price_product_mode_or_metadata_is_rejected_before_checkout
    enabled do
      valid = @client.find_price_by_lookup_key('fixture')
      [{'type' => 'recurring'}, {'livemode' => true}, {'unit_amount' => 550}, {'tax_behavior' => 'inclusive'},
       {'metadata' => valid['metadata'].merge('toybaco_generations' => '5000')}].each do |change|
        @client.price_override = valid.merge(change)
        assert_raises(Toybaco::Checkout::Unavailable) { start! }
      end
      assert_empty @client.create_requests
    end
  end

  def test_wrong_customer_amount_discount_or_tax_cannot_fulfill
    enabled do
      id, event_id = paid_order
      valid = @client.sessions[id].deep_dup
      [{'customer' => 'cus_another'}, {'currency' => 'usd'}, {'amount_subtotal' => 5000},
       {'amount_total' => 5500}, {'automatic_tax' => {'enabled' => true, 'status' => 'failed'}},
       {'total_details' => valid['total_details'].merge('amount_discount' => 1)}].each do |change|
        @client.sessions[id] = valid.merge(change)
        assert_raises(Growth::PurchaseIntent::Unavailable) { complete!(id, event_id) }
        assert_empty grants
      end
    end
  end

  def test_unpaid_wrong_or_future_event_and_incomplete_line_items_do_not_grant
    enabled do
      id, event_id = paid_order
      valid = @client.events[event_id].deep_dup
      [{'type' => 'checkout.session.expired'}, {'created' => NOW.to_i + 1}, {'account' => 'acct_other'},
       {'data' => { 'object' => valid.dig('data', 'object').merge('payment_status' => 'unpaid') }}].each do |change|
        @client.events[event_id] = valid.merge(change)
        assert_raises(Growth::PurchaseIntent::Unavailable) { complete!(id, event_id) }
      end
      @client.events[event_id] = valid
      @client.lines[id]['has_more'] = true
      assert_raises(Growth::PurchaseIntent::Unavailable) { complete!(id, event_id) }
      @client.lines[id]['has_more'] = false
      @client.lines[id]['data'].first['quantity'] = 2
      assert_raises(Growth::PurchaseIntent::Unavailable) { complete!(id, event_id) }
      assert_empty grants
    end
  end

  def test_uncaptured_refunded_or_disputed_charge_does_not_grant
    enabled do
      id, event_id = paid_order
      payment = @client.payments.fetch(@client.sessions[id]['payment_intent'])
      valid = payment['latest_charge'].deep_dup
      [{'captured' => false}, {'amount_captured' => 100}, {'refunded' => true, 'amount_refunded' => 6050}, {'disputed' => true}].each do |change|
        payment['latest_charge'] = valid.merge(change)
        assert_raises(Growth::PurchaseIntent::Unavailable) { complete!(id, event_id) }
      end
      assert_empty grants
    end
  end

  def test_refund_preserves_usage_and_stops_an_inflight_generation_from_consuming
    enabled do
      id, event_id = paid_order
      complete!(id, event_id)
      grants.first.update!(used: 37)
      ledger = Growth::AiLedger.new(@account)
      reservation = ledger.reserve(request_key: 'a' * 32, kind: 'reply_draft', context_digest: 'b' * 64)
      charge = @client.payments.fetch(order.payment_intent_id).fetch('latest_charge')
      charge.merge!('refunded' => true, 'amount_refunded' => 6050)
      2.times { assert_equal 'refunded', Growth::PackRefund.new(client: @client).call(charge['id']) }
      assert_equal 37, grants.first.reload.used
      refute_nil grants.first.revoked_at
      saved = false
      result = ledger.settle(operation_id: reservation['operation_id'], token: reservation['token'], outcome: 'consumed') { saved = true; 'draft:should-not-save' }
      assert_equal 'released', result.fetch('result')
      refute saved
      assert_equal 'refunded', service.refresh!.fetch('state')
    end
  end

  def test_refund_arriving_before_fulfillment_never_issues_a_pack
    enabled do
      id, event_id = paid_order
      charge = @client.payments.fetch(@client.sessions[id]['payment_intent']).fetch('latest_charge')
      charge.merge!('refunded' => true, 'amount_refunded' => 6050)
      assert_equal 'refunded', Growth::PackRefund.new(client: @client).call(charge['id'])
      assert_equal 'refunded', complete!(id, event_id)
      assert_empty grants
    end
  end

  def test_partial_refund_is_held_for_billing_review_without_rewriting_consumption
    enabled do
      id, event_id = paid_order
      complete!(id, event_id)
      charge = @client.payments.fetch(order.payment_intent_id).fetch('latest_charge')
      charge['amount_refunded'] = 100
      assert_equal 'payment_review', Growth::PackRefund.new(client: @client).call(charge['id'])
      assert_equal 'payment_review', service.refresh!.fetch('state')
      assert_raises(Growth::PurchaseIntent::Unavailable) { start!(SecureRandom.uuid) }
      assert_equal 0, grants.first.reload.used
    end
  end

  def test_owner_can_close_old_checkout_after_downgrade_and_new_attempt_is_explicit
    enabled do
      start!
      set_plan('free')
      assert_equal 'expired', service.cancel!.fetch('state')
      set_plan('standard')
      assert_equal 'expired', start!.fetch('state')
      assert_equal 'open', start!(SecureRandom.uuid).fetch('state')
      assert_equal 2, @client.sessions.length
      assert_empty grants
    end
  end

  def test_customer_owner_or_store_change_cannot_transfer_an_order
    enabled do
      id, event_id = paid_order
      @client.sessions[id]['metadata']['toybaco_pack_account_id'] = create(:account).id.to_s
      assert_raises(Growth::PurchaseIntent::Unavailable) { complete!(id, event_id) }
      @client.sessions[id]['metadata']['toybaco_pack_account_id'] = @account.id.to_s
      @account.account_users.find_by!(user_id: @owner.id).destroy!
      assert_raises(Growth::PurchaseIntent::Unavailable) { service.refresh! }
      assert_empty grants
    end
  end

  def test_two_orders_cannot_claim_the_same_captured_payment
    enabled do
      id, event_id = paid_order
      complete!(id, event_id)
      original_payment = order.payment_intent_id
      another_key = SecureRandom.uuid
      start!(another_key)
      other_id = order(another_key).session_id
      other_event = @client.pay!(other_id)
      generated_payment = @client.sessions[other_id]['payment_intent']
      @client.payments[original_payment] = @client.payments.fetch(generated_payment).merge('id' => original_payment)
      @client.payments[original_payment]['latest_charge']['payment_intent'] = original_payment
      @client.sessions[other_id]['payment_intent'] = original_payment
      @client.events[other_event]['data']['object']['payment_intent'] = original_payment
      assert_raises(ActiveRecord::RecordNotUnique) { complete!(other_id, other_event) }
      assert_equal 1, grants.count
      assert_equal 'open', order(another_key).state
    end
  end

  def test_real_routes_preserve_store_boundaries_origin_and_private_payment_fields
    enabled do
      Toybaco::Oidc::SessionReader.stub(:new, OpenStruct.new(user: @owner)) do
        get '/toybaco/growth/packs', params: { account_id: @account.id }
        assert_response :success
        assert_includes response.body, '5,500円（税抜）'
        refute_includes response.body, 'cus_packstore'
        body = { account_id: @account.id, request_key: @request_key }
        post '/toybaco/growth/packs', params: body, headers: { 'Origin' => 'https://elsewhere.invalid' }, as: :json
        assert_response :forbidden
        assert_empty @client.create_requests
        get '/toybaco/growth/packs', params: { account_id: create(:account).id }
        assert_response :forbidden
      end
    end
  end

  def test_real_create_route_uses_server_pack_amount_and_current_store
    previous = ENV.to_h.slice('TOYBACO_STRIPE_MODE', 'TOYBACO_DEPLOYMENT_ENVIRONMENT', 'TOYBACO_STRIPE_KEY')
    ENV.update(ENVIRONMENT.merge('TOYBACO_STRIPE_KEY' => 'fixture'))
    enabled do
      Toybaco::Oidc::SessionReader.stub(:new, OpenStruct.new(user: @owner)) do
        Toybaco::Checkout::Client.stub(:new, @client) do
          post '/toybaco/growth/packs', params: { account_id: @account.id, request_key: @request_key, units: 5000, amount: 1 },
               headers: { 'Origin' => 'http://www.example.com' }, as: :json
          assert_response :success
          assert_equal 'open', response.parsed_body['state']
          assert_equal [500, 5500], order.payload.values_at('units', 'amount')
          get '/toybaco/growth/packs/state', params: { account_id: @account.id, request_key: @request_key }
          assert_response :success
          refute_includes response.body, 'cus_packstore'
          refute_includes response.body, order.nonce
        end
      end
    end
  ensure
    %w[TOYBACO_STRIPE_MODE TOYBACO_DEPLOYMENT_ENVIRONMENT TOYBACO_STRIPE_KEY].each do |name|
      previous&.key?(name) ? ENV[name] = previous[name] : ENV.delete(name)
    end
  end
end
