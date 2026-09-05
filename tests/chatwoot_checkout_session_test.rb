# frozen_string_literal: true

require 'minitest/autorun'
require 'cgi'
require_relative '../overlay/app/lib/toybaco/checkout'

class ChatwootCheckoutSessionTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  AMOUNTS = {
    'light' => { 'month' => 9800, 'year' => 105_840 },
    'standard' => { 'month' => 29_800, 'year' => 321_840 },
    'pro' => { 'month' => 44_800, 'year' => 483_840 }
  }.freeze

  def jpy_price(plan, cycle = 'month')
    key = cycle == 'year' ? "#{plan}-annual" : plan
    terms = Toybaco::Checkout::Catalog.sale(plan, cycle)
    {
      'id' => "price_test#{plan.delete('-')}#{cycle}",
      'currency' => 'jpy',
      'lookup_key' => key,
      'unit_amount' => AMOUNTS.fetch(plan).fetch(cycle),
      'active' => true, 'livemode' => true, 'tax_behavior' => 'exclusive',
      'billing_scheme' => 'per_unit', 'transform_quantity' => nil,
      'recurring' => { 'interval' => cycle, 'interval_count' => 1, 'usage_type' => 'licensed' },
      'metadata' => { 'toybaco_plan' => plan, 'toybaco_plan_version' => terms['plan_version'] },
      'product' => { 'id' => "prod_test#{plan}#{cycle}", 'active' => true,
                     'name' => terms['product_name'], 'description' => terms['description'] }
    }
  end

  def session_params(plan: 'light', cycle: 'month', price: nil, **extras)
    Toybaco::Checkout.session_params(
      plan: plan,
      cycle: cycle,
      price: price || jpy_price(plan, cycle),
      customer_id: 'cus_testjapan1',
      success_url: 'https://toybaco.jp/welcome/',
      cancel_url: "https://toybaco.jp/signup/?plan=#{plan}",
      **extras
    )
  end

  def test_session_uses_supported_japanese_yen_parameters
    params = session_params

    assert_equal 'ja', params['locale']
    assert_equal 'jpy', params['currency']
    refute params.keys.any? { |key| key.start_with?('payment_method_data[billing_details]') }
    assert_equal 'false', params['adaptive_pricing[enabled]']
    assert_equal 'required', params['billing_address_collection']
    assert_equal 'subscription', params['mode']
    assert_equal jpy_price('light')['id'], params['line_items[0][price]']
    refute params.keys.any? { |key| key.include?('[price_data]') }
  end

  def test_customer_prefers_japan_and_japanese
    params = Toybaco::Checkout.customer_params(plan: 'light', cycle: 'month')

    assert_equal 'JP', params['address[country]']
    assert_equal 'ja', params['preferred_locales[]']
    assert_equal 'light', params['metadata[toybaco_plan]']
  end

  def test_all_six_variants_use_the_validated_price_without_creating_products
    %w[light standard pro].product(%w[month year]).each do |plan, cycle|
      price = jpy_price(plan, cycle)
      client = FakeStripe.new(price['lookup_key'] => price)
      Toybaco::Checkout.start!(plan: plan, cycle: cycle, client: client)
      params = client.last_session

      assert_equal price['id'], params['line_items[0][price]']
      assert_equal '1', params['line_items[0][quantity]']
      refute params.keys.any? { |key| key.include?('[price_data]') }
      assert_equal plan, params['metadata[toybaco_plan]']
      assert_equal plan, params['subscription_data[metadata][toybaco_plan]']
      assert_equal price['metadata']['toybaco_plan_version'], params['subscription_data[metadata][toybaco_plan_version]']
      assert_equal price['id'], params['metadata[toybaco_reference_price_id]']
      assert_equal cycle, params['metadata[toybaco_cycle]']
      assert_equal 'true', params['automatic_tax[enabled]']
      assert_equal 'ja', params['locale']
      assert_equal 'jpy', params['currency']
    end
  end

  def test_light_catalog_product_preserves_japanese_name_and_no_posting_description
    price = jpy_price('light')
    assert_equal 'トイバコ ライト', price['product']['name']
    assert_includes price['product']['description'], Toybaco::Checkout::Catalog::LIGHT_NO_SNS
    assert_equal price['id'], session_params(price: price)['line_items[0][price]']
  end

  def test_standard_and_pro_catalog_products_preserve_their_descriptions
    %w[standard pro].each do |plan|
      price = jpy_price(plan)
      refute_includes price['product']['description'], Toybaco::Checkout::Catalog::LIGHT_NO_SNS
      assert_equal price['id'], session_params(plan: plan, price: price)['line_items[0][price]']
    end
  end

  def test_unexpanded_or_unverified_products_are_not_sent_to_checkout
    ['prod_usdleftover1', nil, { 'id' => 'prod_fixture', 'active' => true, 'name' => 'Old USD product' }].each do |product|
      assert_raises(Toybaco::Checkout::Unavailable) { session_params(price: jpy_price('light').merge('product' => product)) }
    end
  end

  def test_price_lookup_requests_jpy_only
    query = Toybaco::Checkout::Client.price_search_query('light')

    assert_includes query, 'currency=jpy'
    assert_includes query, 'lookup_keys[]=light'
    refute_includes query, 'usd'
    assert_includes query, 'expand[]=data.product'
  end

  def test_annual_lookup_keys_and_cycle_survive
    assert_equal 'light-annual', Toybaco::Checkout.lookup_key('light', 'year')
    params = session_params(plan: 'pro', cycle: 'year')

    assert_equal 'pro', params['metadata[toybaco_plan]']
    assert_equal 'year', params['metadata[toybaco_cycle]']
    assert_equal jpy_price('pro', 'year')['id'], params['line_items[0][price]']
    refute params.keys.any? { |key| key.include?('[price_data]') }
  end

  def test_non_jpy_price_fails_closed
    error = assert_raises(Toybaco::Checkout::NonJpyPrice) do
      session_params(price: { 'id' => 'price_testusd1', 'currency' => 'usd' })
    end
    assert_match(/JPY/i, error.message)
  end

  def test_missing_currency_fails_closed
    assert_raises(Toybaco::Checkout::NonJpyPrice) do
      session_params(price: { 'id' => 'price_testnone1', 'unit_amount' => 9800 })
    end
  end

  def test_jpy_price_without_amount_fails_closed
    assert_raises(Toybaco::Checkout::NonJpyPrice) do
      session_params(price: { 'id' => 'price_testnoamt1', 'currency' => 'jpy' })
    end
  end

  def test_interval_mismatch_fails_closed
    price = jpy_price('light').merge('recurring' => { 'interval' => 'year' })
    assert_raises(Toybaco::Checkout::NonJpyPrice) do
      session_params(plan: 'light', cycle: 'month', price: price)
    end
  end

  def test_unknown_plan_is_rejected
    assert_raises(Toybaco::Checkout::InvalidPlan) do
      Toybaco::Checkout.normalize_selection('premium', 'month')
    end
    assert_raises(Toybaco::Checkout::InvalidPlan) do
      Toybaco::Checkout.normalize_selection('light', 'weekly')
    end
  end

  def test_start_keeps_lp_plan_on_session_and_customer
    client = FakeStripe.new(
      'light' => jpy_price('light'),
      'setup-standard' => { 'id' => 'price_testset1', 'currency' => 'jpy' },
      'opt-store' => { 'id' => 'price_teststore1', 'currency' => 'jpy' }
    )

    session = Toybaco::Checkout.start!(plan: 'light', client: client)

    assert_equal 'https://checkout.stripe.com/c/pay/cs_testjapan1', session['url']
    assert_equal 'light', client.last_session['metadata[toybaco_plan]']
    assert_equal jpy_price('light')['id'], client.last_session['line_items[0][price]']
    refute client.last_session.keys.any? { |key| key.include?('[price_data]') }
    assert_equal 'ja', client.last_session['locale']
    assert_equal 'jpy', client.last_session['currency']
    refute client.last_session.keys.any? { |key| key.start_with?('payment_method_data[billing_details]') }
    assert_equal 'JP', client.last_customer['address[country]']
    assert_equal 'cus_testjapan1', client.last_session['customer']
  end

  def test_staging_checkout_returns_to_staging_and_keeps_selected_terms
    client = FakeStripe.new('pro-annual' => jpy_price('pro', 'year').merge('livemode' => false))
    env = { 'TOYBACO_DEPLOYMENT_ENVIRONMENT' => 'staging', 'TOYBACO_STRIPE_MODE' => 'test' }

    Toybaco::Checkout.start!(plan: 'pro', cycle: 'year', client: client, environment: env)

    assert_equal 'https://staging.toybaco.jp/welcome/', client.last_session['success_url']
    uri = URI.parse(client.last_session['cancel_url'])
    assert_equal 'staging.toybaco.jp', uri.host
    assert_equal '/signup/', uri.path
    assert_equal({ 'plan' => 'pro', 'cycle' => 'year', 'version' => '2026-09-06.1' }, URI.decode_www_form(uri.query).to_h)
  end

  def test_staging_rejects_live_and_unknown_environment_before_creating_customer
    [{ 'TOYBACO_DEPLOYMENT_ENVIRONMENT' => 'staging', 'TOYBACO_STRIPE_MODE' => 'live' },
     { 'TOYBACO_DEPLOYMENT_ENVIRONMENT' => 'preview', 'TOYBACO_STRIPE_MODE' => 'test' }].each do |env|
      client = FakeStripe.new('light' => jpy_price('light'))
      assert_raises(Toybaco::Checkout::Unavailable) do
        Toybaco::Checkout.start!(plan: 'light', client: client, environment: env)
      end
      assert_nil client.last_customer
      assert_nil client.last_session
    end
  end

  def test_return_urls_cannot_cross_environment_or_redirect_to_an_untrusted_origin
    env = { 'TOYBACO_DEPLOYMENT_ENVIRONMENT' => 'staging', 'TOYBACO_STRIPE_MODE' => 'test' }
    ['https://toybaco.jp/welcome/', 'https://staging.toybaco.jp.evil.example/',
     'http://staging.toybaco.jp/', 'https://evil.example/',
     'https://user@staging.toybaco.jp/', 'https://staging.toybaco.jp:444/',
     'https://staging.toybaco.jp/#fragment'].each do |url|
      result = Toybaco::Checkout::Resolver.success_url(env.merge('TOYBACO_CHECKOUT_SUCCESS_URL' => url))
      assert_equal 'https://staging.toybaco.jp/welcome/', result
    end
    assert_equal 'https://toybaco.jp/welcome/', Toybaco::Checkout::Resolver.success_url(
      'TOYBACO_CHECKOUT_SUCCESS_URL' => 'https://staging.toybaco.jp/welcome/'
    )
  end

  def test_start_fails_closed_when_resolved_price_is_not_jpy
    client = FakeStripe.new('standard' => { 'id' => 'price_testusdstd', 'currency' => 'usd' })

    assert_raises(Toybaco::Checkout::NonJpyPrice) do
      Toybaco::Checkout.start!(plan: 'standard', client: client)
    end
    assert_nil client.last_customer
    assert_nil client.last_session
  end

  def test_env_price_override_still_requires_jpy
    client = FakeStripe.new(
      'price_testoverride1' => { 'id' => 'price_testoverride1', 'currency' => 'eur' }
    )
    env = { 'TOYBACO_STRIPE_PRICE_PRO' => 'price_testoverride1' }

    assert_raises(Toybaco::Checkout::NonJpyPrice) do
      Toybaco::Checkout.start!(plan: 'pro', client: client, environment: env)
    end
  end

  def test_optional_non_jpy_price_is_dropped
    client = FakeStripe.new(
      'light' => jpy_price('light'),
      'setup-standard' => { 'id' => 'price_testusdopt', 'currency' => 'usd' },
      'opt-store' => { 'id' => 'price_teststore1', 'currency' => 'jpy' }
    )

    Toybaco::Checkout.start!(plan: 'light', client: client)

    refute client.last_session.key?('optional_items[0][price]') &&
           client.last_session['optional_items[0][price]'] == 'price_testusdopt'
    assert_equal 'price_teststore1', client.last_session['optional_items[0][price]']
  end

  def test_lp_plan_buttons_pass_query_into_signup
    index_path = File.join(ROOT, 'site/index.html')
    pricing_path = File.join(ROOT, 'site/pricing/index.html')
    skip 'site HTML はこの品質スナップショットに含まれない' unless File.file?(index_path) && File.file?(pricing_path)

    index = File.read(index_path)
    pricing = File.read(pricing_path)

    assert_includes(index, 'signup/?plan=light')
    assert_includes(index, 'signup/?plan=standard')
    assert_includes(index, 'signup/?plan=pro')
    assert_includes(pricing, '../signup/?plan=light')
    assert_includes(pricing, '../signup/?plan=standard')
    assert_includes(pricing, '../signup/?plan=pro')
    refute_match(%r{href="signup/"\s*>このプランではじめる}, index)
    refute_match(%r{href="../signup/"\s*>このプランではじめる}, pricing)
  end

  def test_signup_keeps_plan_into_checkout_urls
    signup_path = File.join(ROOT, 'site/signup/index.html')
    skip 'site HTML はこの品質スナップショットに含まれない' unless File.file?(signup_path)

    signup = File.read(signup_path)

    %w[light standard pro].each do |plan|
      assert_includes(signup, %(data-plan="#{plan}"))
      assert_includes(CGI.unescapeHTML(signup), "https://app.toybaco.jp/toybaco/checkout?plan=#{plan}&cycle=month")
      assert_includes(CGI.unescapeHTML(signup), "https://app.toybaco.jp/toybaco/checkout?plan=#{plan}&cycle=year")
    end
    assert_includes(signup, "params.get('plan')")
    assert_includes(signup, 'SNS 投稿機能はありません')
    refute_includes(signup, 'buy.stripe.com')
  end

  def test_new_sales_reject_unverified_prices_before_creating_customer_or_session
    mutations = [
      ->(p) { p['active'] = false }, ->(p) { p.delete('active') },
      ->(p) { p['tax_behavior'] = 'unspecified' }, ->(p) { p['tax_behavior'] = 'inclusive' },
      ->(p) { p['recurring']['interval_count'] = 2 }, ->(p) { p['recurring']['usage_type'] = 'metered' },
      ->(p) { p['billing_scheme'] = 'tiered' }, ->(p) { p['transform_quantity'] = { 'divide_by' => 10, 'round' => 'up' } },
      ->(p) { p['metadata']['toybaco_plan_version'] = 'old-version' },
      ->(p) { p['metadata']['toybaco_plan'] = 'standard' }, ->(p) { p['metadata'] = {} },
      ->(p) { p['product']['active'] = false }, ->(p) { p['product']['name'] = 'Old USD product' },
      ->(p) { p['product']['description'] = '古い料金・機能の説明' },
      ->(p) { p['livemode'] = false }, ->(p) { p.delete('livemode') }
    ]
    mutations.each_with_index do |mutate, index|
      price = jpy_price('light')
      mutate.call(price)
      price_env = Toybaco::Checkout::Catalog.sale('light', 'month').dig('cycles', 'month', 'stripe', 'live', 'price_env')
      [{}, { price_env => price['id'] }].each do |environment|
        client = FakeStripe.new('light' => price)
        assert_raises(Toybaco::Checkout::Unavailable, "invalid sale #{index}, override=#{!environment.empty?}") do
          Toybaco::Checkout.start!(plan: 'light', client: client, environment: environment)
        end
        assert_nil client.last_customer
        assert_nil client.last_session
      end
    end
  end

  def test_lookup_and_explicit_price_id_both_request_expanded_product
    client = Toybaco::Checkout::Client.new('fixture-key')
    requests = []
    client.define_singleton_method(:request) do |method, path|
      requests << [method, path]
      { 'data' => [{ 'id' => 'price_fixture' }] }
    end
    client.find_price_by_lookup_key('light')
    client.retrieve_price('price_fixture')
    assert_equal [:get, '/v1/prices?lookup_keys[]=light&currency=jpy&active=true&limit=1&expand[]=data.product'], requests[0]
    assert_equal [:get, '/v1/prices/price_fixture?expand[]=product'], requests[1]
  end

  def test_routes_and_controller_are_public_checkout
    routes = File.read(File.join(ROOT, 'overlay/app/config/initializers/toybaco_checkout.rb'))
    controller = File.read(File.join(ROOT, 'overlay/app/app/controllers/toybaco/checkout_controller.rb'))
    error_page = File.read(File.join(ROOT, 'overlay/app/app/views/toybaco/checkout/error.html.erb'))

    assert_includes(routes, "get '/toybaco/checkout'")
    assert_includes(routes, "post '/toybaco/checkout'")
    assert_includes(controller, 'Toybaco::Checkout.start!')
    assert_includes(controller, 'params[:plan]')
    assert_includes(error_page, 'お申し込みを続けられません')
    refute_match(/sk_live|rk_live|whsec_|sk_test/, "#{routes}#{controller}#{error_page}")
  end

  class FakeStripe
    attr_reader :last_customer, :last_session

    def initialize(prices)
      @prices = prices
    end

    def find_price_by_lookup_key(key)
      @prices[key]
    end

    def retrieve_price(price_id)
      @prices[price_id] || @prices.values.find { |price| price['id'] == price_id }
    end

    def create_customer(params)
      @last_customer = params
      { 'id' => 'cus_testjapan1' }
    end

    def create_checkout_session(params)
      @last_session = params
      { 'id' => 'cs_testjapan1', 'url' => 'https://checkout.stripe.com/c/pay/cs_testjapan1' }
    end
  end
end
