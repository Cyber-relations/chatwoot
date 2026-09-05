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
    {
      'id' => "price_test#{plan.delete('-')}#{cycle}",
      'currency' => 'jpy',
      'lookup_key' => key,
      'unit_amount' => AMOUNTS.fetch(plan).fetch(cycle),
      'recurring' => { 'interval' => cycle }
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
    assert_equal 'jpy', params['line_items[0][price_data][currency]']
    refute params.key?('line_items[0][price]')
  end

  def test_customer_prefers_japan_and_japanese
    params = Toybaco::Checkout.customer_params(plan: 'light', cycle: 'month')

    assert_equal 'JP', params['address[country]']
    assert_equal 'ja', params['preferred_locales[]']
    assert_equal 'light', params['metadata[toybaco_plan]']
  end

  def test_plan_id_passthrough_for_each_self_serve_plan
    %w[light standard pro].each do |plan|
      price = jpy_price(plan)
      params = session_params(plan: plan, price: price)

      assert_equal plan, params['metadata[toybaco_plan]']
      assert_equal plan, params['subscription_data[metadata][toybaco_plan]']
      assert_equal 'jpy', params['line_items[0][price_data][currency]']
      assert_equal price['unit_amount'].to_s, params['line_items[0][price_data][unit_amount]']
      refute params.key?('line_items[0][price]')
      refute params.key?('line_items[0][price]')
      assert_equal price['id'], params['metadata[toybaco_reference_price_id]']
      assert_equal 'month', params['metadata[toybaco_cycle]']
    end
  end

  def test_light_description_states_no_sns_posting
    params = session_params(plan: 'light')
    description = params['line_items[0][price_data][product_data][description]']

    assert_equal 'トイバコ ライト', params['line_items[0][price_data][product_data][name]']
    assert_includes description, Toybaco::Checkout::Catalog::LIGHT_NO_SNS
  end

  def test_standard_and_pro_do_not_claim_light_has_no_posting
    %w[standard pro].each do |plan|
      description = session_params(plan: plan)['line_items[0][price_data][product_data][description]']

      refute_includes description, Toybaco::Checkout::Catalog::LIGHT_NO_SNS
      refute_includes description, 'SNS 投稿機能はありません'
    end
  end

  def test_leftover_usd_product_is_not_sent_to_session
    price = jpy_price('light').merge('product' => 'prod_usdleftover1')
    params = session_params(price: price)

    refute_includes params.values, 'prod_usdleftover1'
    refute params.key?('line_items[0][price]')
    assert_equal price['id'], params['metadata[toybaco_reference_price_id]']
    assert_equal 'jpy', params['line_items[0][price_data][currency]']
  end

  def test_price_lookup_requests_jpy_only
    query = Toybaco::Checkout::Client.price_search_query('light')

    assert_includes query, 'currency=jpy'
    assert_includes query, 'lookup_keys[]=light'
    refute_includes query, 'usd'
  end

  def test_annual_lookup_keys_and_cycle_survive
    assert_equal 'light-annual', Toybaco::Checkout.lookup_key('light', 'year')
    params = session_params(plan: 'pro', cycle: 'year')

    assert_equal 'pro', params['metadata[toybaco_plan]']
    assert_equal 'year', params['metadata[toybaco_cycle]']
    assert_equal 'year', params['line_items[0][price_data][recurring][interval]']
    assert_equal '483840', params['line_items[0][price_data][unit_amount]']
    refute params.key?('line_items[0][price]')
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
    assert_equal 'jpy', client.last_session['line_items[0][price_data][currency]']
    assert_equal '9800', client.last_session['line_items[0][price_data][unit_amount]']
    assert_includes client.last_session['line_items[0][price_data][product_data][description]'],
                    Toybaco::Checkout::Catalog::LIGHT_NO_SNS
    refute client.last_session.key?('line_items[0][price]')
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
