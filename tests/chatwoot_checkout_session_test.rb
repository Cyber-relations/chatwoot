# frozen_string_literal: true

require 'minitest/autorun'
require 'cgi'
require 'uri'
require_relative '../overlay/app/lib/toybaco/checkout'

class ChatwootCheckoutSessionTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  # New sales since the 2026-09-26 sales switch: 2026-09-25.1 at the prices fixed by the catalog preparation (#319).
  VERSION = '2026-09-25.1'
  FORMER = '2026-09-06.1'

  AMOUNTS = {
    'light' => { 'month' => 9800, 'year' => 105_840 },
    'standard' => { 'month' => 19_800, 'year' => 213_840 },
    'pro' => { 'month' => 29_800, 'year' => 321_840 }
  }.freeze

  def lookup(plan, cycle = 'month')
    "#{plan}-growth-20260925#{'-annual' if cycle == 'year'}"
  end

  def jpy_price(plan, cycle = 'month')
    terms = Toybaco::Checkout::Catalog.sale(plan, cycle)
    {
      'id' => "price_test#{plan.delete('-')}#{cycle}",
      'currency' => 'jpy',
      'lookup_key' => lookup(plan, cycle),
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

  def test_current_sales_are_the_growth_version_with_its_own_lookup_keys
    %w[light standard pro].product(%w[month year]).each do |plan, cycle|
      terms = Toybaco::Checkout::Catalog.sale(plan, cycle)
      assert_equal [VERSION, AMOUNTS.fetch(plan).fetch(cycle)], [terms['plan_version'], terms.dig('cycles', cycle, 'amount')]
      assert_equal lookup(plan, cycle), Toybaco::Checkout.lookup_key(plan, cycle)
      assert_raises(Toybaco::PlanCatalog::Invalid) { Toybaco::Checkout::Catalog.sale(plan, cycle, version: FORMER) }
    end
    assert_equal %w[light standard pro], Toybaco::Checkout::Catalog::PLANS
  end

  def test_light_catalog_product_preserves_japanese_name_and_published_description
    price = jpy_price('light')
    assert_equal 'トイバコ ライト', price['product']['name']
    # The former light version had no SNS posting; the growth light includes it.
    assert_equal '1店舗分。問い合わせ・SNS投稿・AIを、スタッフ全員で。', price['product']['description']
    refute_includes price['product']['description'], Toybaco::Checkout::Catalog::LIGHT_NO_SNS
    assert_includes Toybaco::PlanCatalog.default.definition('light', FORMER)['description'], Toybaco::Checkout::Catalog::LIGHT_NO_SNS
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
    assert_equal 'light-growth-20260925-annual', Toybaco::Checkout.lookup_key('light', 'year')
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
      lookup('light') => jpy_price('light'),
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
    client = FakeStripe.new(lookup('pro', 'year') => jpy_price('pro', 'year').merge('livemode' => false))
    env = { 'TOYBACO_DEPLOYMENT_ENVIRONMENT' => 'staging', 'TOYBACO_STRIPE_MODE' => 'test' }

    Toybaco::Checkout.start!(plan: 'pro', cycle: 'year', client: client, environment: env)

    assert_equal 'https://staging.toybaco.jp/welcome/', client.last_session['success_url']
    uri = URI.parse(client.last_session['cancel_url'])
    assert_equal 'staging.toybaco.jp', uri.host
    assert_equal '/signup/', uri.path
    assert_equal({ 'plan' => 'pro', 'cycle' => 'year', 'version' => VERSION }, URI.decode_www_form(uri.query).to_h)
  end

  def test_staging_rejects_live_and_unknown_environment_before_creating_customer
    [{ 'TOYBACO_DEPLOYMENT_ENVIRONMENT' => 'staging', 'TOYBACO_STRIPE_MODE' => 'live' },
     { 'TOYBACO_DEPLOYMENT_ENVIRONMENT' => 'preview', 'TOYBACO_STRIPE_MODE' => 'test' }].each do |env|
      client = FakeStripe.new(lookup('light') => jpy_price('light'))
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
    client = FakeStripe.new(lookup('standard') => { 'id' => 'price_testusdstd', 'currency' => 'usd' })

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
    env = { 'TOYBACO_STRIPE_PRICE_GROWTH_20260925_PRO' => 'price_testoverride1' }
    assert_equal env.keys.first, Toybaco::Checkout::Catalog.sale('pro', 'month').dig('cycles', 'month', 'stripe', 'live', 'price_env')

    assert_raises(Toybaco::Checkout::NonJpyPrice) do
      Toybaco::Checkout.start!(plan: 'pro', client: client, environment: env)
    end
  end

  def test_optional_items_are_never_offered_even_when_their_prices_exist
    client = FakeStripe.new(
      lookup('light') => jpy_price('light'),
      'setup-standard' => { 'id' => 'price_testusdopt', 'currency' => 'usd' },
      'opt-store' => { 'id' => 'price_teststore1', 'currency' => 'jpy' }
    )

    Toybaco::Checkout.start!(plan: 'light', client: client)

    refute client.last_session.keys.any? { |key| key.start_with?('optional_items') }
    refute_includes client.lookups, 'setup-standard'
    refute_includes client.lookups, 'opt-store'
  end

  def test_lp_plan_buttons_pass_query_into_signup
    index_path = File.join(ROOT, 'site/index.html')
    pricing_path = File.join(ROOT, 'site/pricing/index.html')
    skip 'site HTML はこの品質スナップショットに含まれない' unless File.file?(index_path) && File.file?(pricing_path)

    [index_path, pricing_path].each do |path|
      html = File.read(path)
      %w[free light standard pro].each do |plan|
        href = html[/data-lp-plan-link="#{plan}" href="([^"]+)"/, 1]
        refute_nil href, "#{path}: #{plan} has a plan link"
        uri = URI.parse(CGI.unescapeHTML(href))
        assert_equal '/signup/', uri.path
        assert_nil uri.host
        expected = { 'plan' => plan, 'version' => '2026-09-25.1' }
        expected['cycle'] = 'month' unless plan == 'free'
        assert_equal expected, URI.decode_www_form(uri.query).to_h
      end
    end
  end

  def test_lp_candidate_links_the_version_the_application_accepts
    lp_path = File.join(ROOT, 'scripts/lp_pricing_candidate.py')
    skip 'LP 候補 script はこの品質スナップショットに含まれない' unless File.file?(lp_path)

    assert_equal [[Toybaco::GrowthTerms::VERSION]], File.read(lp_path).scan(/^VERSION = '([^']+)'$/)
  end

  def test_signup_hands_the_selected_plan_to_the_application_since_the_sales_switch
    signup_path = File.join(ROOT, 'site/signup/index.html')
    skip 'site HTML はこの品質スナップショットに含まれない' unless File.file?(signup_path)

    signup = File.read(signup_path)
    %w[free light standard pro].each do |plan|
      href = signup[/data-lp-plan-link="#{plan}" href="([^"]+)"/, 1]
      refute_nil href, "signup: #{plan} has a plan link"
      uri = URI.parse(CGI.unescapeHTML(href))
      assert_equal %w[https app.toybaco.jp], [uri.scheme, uri.host]
      if plan == 'free'
        # The free registration opens by the catalog's free_registration_version, not by a query.
        assert_equal ['/toybaco/free/signup', nil], [uri.path, uri.query]
        next
      end
      assert_equal '/toybaco/checkout', uri.path
      query = URI.decode_www_form(uri.query).to_h
      assert_equal({ 'plan' => plan, 'version' => VERSION, 'cycle' => 'month' }, query)
      # The checkout accepts exactly this version for the linked plan and cycle.
      assert_equal VERSION, Toybaco::Checkout::Catalog.sale(query['plan'], query['cycle'], version: query['version'])['plan_version']
    end
    free = Toybaco::PlanCatalog.default.definition('free', Toybaco::PlanCatalog.default.data.fetch('free_registration_version'))
    assert_equal [VERSION, true, {}], [free['plan_version'], free['sellable'], free['cycles']]
    assert_includes(signup, '/assets/lp-candidate.js?')
    assert_includes(signup, 'data-lp-cycle="year"')
    refute_includes(signup, 'SNS 投稿機能はありません')
    refute_includes(signup, 'buy.stripe.com')
    refute_includes(signup, '/contact/?topic=service')
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
        client = FakeStripe.new(lookup('light') => price)
        assert_raises(Toybaco::Checkout::Unavailable, "invalid sale #{index}, override=#{!environment.empty?}") do
          Toybaco::Checkout.start!(plan: 'light', client: client, environment: environment)
        end
        assert_nil client.last_customer
        assert_nil client.last_session
      end
    end
  end

  # 開通(Growth::OpeningTerms)は割引 0 と「Session 小計 = 購読明細の小計」を要求する。新規店舗の決済画面に
  # 割引コード欄や任意オプションを出すと、支払いは済んでも店舗が開通しない。
  def test_new_store_checkout_has_one_subscription_line_and_no_promotion_codes
    %w[light standard pro].product(%w[month year]).each do |plan, cycle|
      price = jpy_price(plan, cycle)
      client = FakeStripe.new(Toybaco::Checkout.lookup_key(plan, cycle) => price,
                              'setup-standard' => { 'id' => 'price_testset1', 'currency' => 'jpy' },
                              'opt-store' => { 'id' => 'price_teststore1', 'currency' => 'jpy' })
      Toybaco::Checkout.start!(plan: plan, cycle: cycle, client: client)
      params = client.last_session

      assert_equal 'false', params['allow_promotion_codes'], "#{plan}/#{cycle}"
      assert_equal({ 'line_items[0][price]' => price['id'], 'line_items[0][quantity]' => '1' },
                   params.select { |key, _| key.start_with?('line_items') }, "#{plan}/#{cycle}")
      refute params.keys.any? { |key| key.start_with?('optional_items', 'discounts') }, "#{plan}/#{cycle}"
      assert_equal [Toybaco::Checkout.lookup_key(plan, cycle)], client.lookups, "#{plan}/#{cycle}"
    end
    assert_equal 'false', session_params['allow_promotion_codes']
  end

  def test_industry_choices_end_with_other_which_applies_no_pack
    params = session_params
    options = (0...20).map do |index|
      params.values_at("custom_fields[1][dropdown][options][#{index}][value]", "custom_fields[1][dropdown][options][#{index}][label]")
    end.take_while(&:first)
    assert_equal 13, options.length
    assert_equal %w[other その他], options.last
    assert_equal Toybaco::Checkout::Catalog::OTHER_INDUSTRY, options.last.first
    assert(options.all? { |value, _| value.match?(/\A[a-z]+\z/) }, 'Stripe dropdown values stay alphanumeric')
    assert_equal '業種(該当する業種は初期設定パックを適用します)', params['custom_fields[1][label][custom]']
  end

  def test_checkout_pages_use_the_published_terms_and_an_existing_contact_route
    controller = File.read(File.join(ROOT, 'overlay/app/app/controllers/toybaco/checkout_controller.rb'))
    error_page = File.read(File.join(ROOT, 'overlay/app/app/views/toybaco/checkout/error.html.erb'))
    confirm = File.read(File.join(ROOT, 'overlay/app/app/views/toybaco/checkout/confirm.html.erb'))
    refute_includes "#{controller}#{error_page}", '右下のチャット'
    assert_includes controller, '決済ページの作成に失敗しました。お手数ですが、お問い合わせフォームからご連絡ください。'
    assert_includes error_page, '<a href="https://toybaco.jp/contact/">お問い合わせフォーム</a>'
    assert_includes confirm, '<dt>スタッフ</dt>'
    assert_includes confirm, "shared_ai ? 'AIアシスタント' : 'AI応答'"
    refute_match(/担当者|業務AI/, confirm)
    assert_includes confirm, '<p>現在の料金と利用条件をご確認のうえ、決済へお進みください。</p>'
    refute_includes confirm, '以前のページやリンクから'
  end

  # 確認画面の SNS 投稿は、カタログの投稿先上限がある契約では件数を出す(上限の無い契約は従来どおり)。
  def test_confirmation_states_the_posting_account_limit_from_the_catalog
    growth = Toybaco::PlanCatalog.default.definition('standard', '2026-09-25.1')
    assert_includes render_confirmation(growth, 'month'),
                    "<dt>SNS投稿</dt><dd>投稿先 #{growth.dig('entitlements', 'limits', 'posting_accounts')}アカウントまで</dd>"
    light = Toybaco::PlanCatalog.default.definition('light', '2026-09-25.1')
    assert_includes render_confirmation(light, 'year'),
                    "<dt>SNS投稿</dt><dd>投稿先 #{light.dig('entitlements', 'limits', 'posting_accounts')}アカウントまで</dd>"
    without_limit = Marshal.load(Marshal.dump(growth))
    without_limit['entitlements']['limits'].delete('posting_accounts')
    assert_includes render_confirmation(without_limit, 'month'), '<dt>SNS投稿</dt><dd>利用できます</dd>'
    without_posting = Marshal.load(Marshal.dump(growth))
    without_posting['entitlements']['features']['posting'] = false
    assert_includes render_confirmation(without_posting, 'month'), '<dt>SNS投稿</dt><dd>含まれません</dd>'
  end

  def render_confirmation(terms, cycle)
    require 'erb'
    view = Object.new
    view.instance_variable_set(:@terms, terms)
    view.instance_variable_set(:@cycle, cycle)
    view.instance_variable_set(:@plan, terms.fetch('plan_id'))
    view.define_singleton_method(:number_with_delimiter) { |value| value.to_s.reverse.scan(/\d{1,3}/).join(',').reverse }
    template = File.read(File.join(ROOT, 'overlay/app/app/views/toybaco/checkout/confirm.html.erb'))
    ERB.new(template).result(view.instance_eval { binding })
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

  def test_terms_consent_is_required_on_every_session_even_without_in_app_consent
    params = session_params

    assert_equal 'required', params['consent_collection[terms_of_service]']
    assert_equal Toybaco::LegalTerms::TOS_MESSAGE, params['custom_text[terms_of_service_acceptance][message]']
    # The growth version returns to the free plan at the period end, so new sessions say so.
    assert_equal Toybaco::LegalTerms::SUBMIT_MESSAGE, params['custom_text[submit][message]']
    assert_equal Toybaco::LegalTerms::VERSION, params['metadata[toybaco_terms_version]']
    assert_equal Toybaco::LegalTerms::VERSION, params['subscription_data[metadata][toybaco_terms_version]']
    refute params.key?('metadata[toybaco_terms_accepted_at]')
    refute params.key?('subscription_data[metadata][toybaco_terms_accepted_at]')
  end

  def test_in_app_consent_time_is_kept_on_the_session_and_the_subscription
    consent = Toybaco::LegalTerms.consent(Time.utc(2026, 9, 25, 3, 4, 5))
    client = FakeStripe.new(lookup('light') => jpy_price('light'))
    Toybaco::Checkout.start!(plan: 'light', client: client, consent: consent)
    params = client.last_session

    assert_equal 'required', params['consent_collection[terms_of_service]']
    assert_equal Toybaco::LegalTerms::VERSION, params['metadata[toybaco_terms_version]']
    assert_equal '2026-09-25T03:04:05Z', params['metadata[toybaco_terms_accepted_at]']
    assert_equal '2026-09-25T03:04:05Z', params['subscription_data[metadata][toybaco_terms_accepted_at]']
    assert_equal({ 'terms_version' => Toybaco::LegalTerms::VERSION, 'accepted_at' => '2026-09-25T03:04:05Z' }, consent)
    assert_raises(ArgumentError) { Toybaco::Checkout.start!(plan: 'light', client: client, consnet: consent) }
  end

  def test_submit_text_names_the_free_plan_only_for_versions_that_return_to_it
    growth = Toybaco::Checkout::Catalog.sale('standard', 'month')
    legacy = Toybaco::PlanCatalog.default.definition('standard', FORMER)
    assert_equal VERSION, growth['plan_version']

    assert Toybaco::LegalTerms.returns_to_free?(growth)
    refute Toybaco::LegalTerms.returns_to_free?(legacy)
    assert_equal Toybaco::LegalTerms::SUBMIT_MESSAGE, Toybaco::LegalTerms.submit_message(growth)
    assert_includes Toybaco::LegalTerms::SUBMIT_MESSAGE, '契約期間末に無料プランへ移ります'
    refute_includes Toybaco::LegalTerms.submit_message(legacy), '無料プラン'
    form = Toybaco::Checkout::SessionForm.terms_consent(nil, submit_message: Toybaco::LegalTerms.submit_message(growth))
    assert_equal Toybaco::LegalTerms::SUBMIT_MESSAGE, form['custom_text[submit][message]']
  end

  def test_terms_text_fits_stripe_limits_and_links_the_published_pages
    legal = Toybaco::LegalTerms
    assert_equal '[利用規約](https://toybaco.jp/terms/)と[特定商取引法に基づく表記](https://toybaco.jp/tokushoho/)に同意します。',
                 legal::TOS_MESSAGE
    [legal::TOS_MESSAGE, legal::SUBMIT_MESSAGE, legal::LEGACY_SUBMIT_MESSAGE].each { |text| assert_operator text.length, :<=, 1200 }
    params = session_params(consent: legal.consent)
    params.each do |key, value|
      next unless key.start_with?('metadata[', 'subscription_data[metadata][')

      assert_operator key[/\[([^\[\]]+)\]\z/, 1].length, :<=, 40
      assert_operator value.length, :<=, 500
    end
    assert_match(/\A\d{4}-\d{2}-\d{2}\.\d+\z/, legal::VERSION)
    [legal::TERMS_URL, legal::TOKUSHOHO_URL, legal::PRIVACY_URL].each { |url| assert_match(%r{\Ahttps://toybaco\.jp/[a-z]+/\z}, url) }
  end

  def test_consent_entries_are_validated_before_they_are_saved
    legal = Toybaco::LegalTerms
    entry = legal.entry('opening_checkout', '2026-09-25T12:00:00+09:00', { session_id: 'cs_test_a1', stripe_consent: 'accepted', user_id: 7 })

    assert_equal({ 'route' => 'opening_checkout', 'terms_version' => legal::VERSION, 'accepted_at' => '2026-09-25T03:00:00Z',
                   'user_id' => 7, 'session_id' => 'cs_test_a1', 'stripe_consent' => 'accepted' }, entry)
    [['unknown', '2026-09-25T03:00:00Z', {}], ['trial', 'not-a-time', {}], ['trial', Time.now.utc, { terms_version: 'v1' }],
     ['trial', Time.now.utc, { session_id: 'sub_1' }], ['trial', Time.now.utc, { stripe_consent: 'declined' }],
     ['trial', Time.now.utc, { user_id: '7' }], ['trial', Time.now.utc, { extra: 1 }]].each do |route, time, details|
      assert_raises(ArgumentError) { legal.entry(route, time, details) }
    end
    assert legal.duplicate?(entry, entry.merge('accepted_at' => '2026-09-26T00:00:00Z'))
    refute legal.duplicate?(entry, entry.merge('session_id' => 'cs_test_other'))
    assert_nil legal.accepted_in('toybaco_plan' => 'light')
    assert_equal({ terms_version: 'v', accepted_at: 't' }, legal.accepted_in('toybaco_terms_version' => 'v', 'toybaco_terms_accepted_at' => 't'))
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
      lookups << key
      @prices[key]
    end

    def lookups
      @lookups ||= []
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
