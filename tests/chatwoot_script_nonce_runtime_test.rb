# frozen_string_literal: true

require 'rails/test_help'
require 'minitest/mock'

puts 'TOYBACO_CSP_NONCE_SUITE_BEGIN'
Minitest.after_run { puts 'TOYBACO_CSP_NONCE_SUITE_END' }

# Actual Rails request/helper/brand-injector and enforced script boundary.
class ChatwootScriptNonceRuntimeTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = true

  def setup
    host! 'www.example.com'
    https!
  end

  def render_login
    manifest = ViteRuby.instance.manifest
    manifest.stub(:resolve_entries, { scripts: [], imports: [], stylesheets: [] }) do
      manifest.stub(:vite_client_src, nil) { get '/app/login' }
    end
    assert_response :success
    Nokogiri::HTML(response.body)
  end

  def nonce_from(document)
    nonces = document.css('script[nonce]').map { |script| script['nonce'] }.uniq
    assert_equal 1, nonces.length, 'all explicitly trusted scripts must share one request nonce'
    assert_match(/\A[A-Za-z0-9+\/]{24}\z/, nonces.first)
    nonces.first
  end

  def test_real_templates_and_injector_share_random_request_nonce
    document = render_login
    nonce = nonce_from(document)
    config = document.at_css('script[data-toybaco-post-config]')
    assert config, 'actual brand injector must run'
    assert_equal nonce, config['nonce']
    assert document.css('script[nonce]').any? { |node| node.text.include?('window.chatwootConfig') }
    assert_includes response.headers['Content-Security-Policy'], "frame-ancestors 'self'"
    assert_includes response.headers['Content-Security-Policy'], Toybaco::ScriptPolicy.policy(nonce)
    assert_includes response.headers['Cache-Control'].split(',').map(&:strip), 'no-store'
    assert response.headers['Content-Security-Policy-Report-Only'], 'observation policy stays separate'
    # No current-session ID or repeatable request input is used as the nonce.
    assert nonce != nonce_from(render_login), 'fresh document requests must use independent nonces'
  end

  def test_portal_drive_and_frame_visits_require_a_new_document_for_the_response_nonce
    account = Account.create!(name: 'CSP portal fixture')
    account.enable_features!('help_center')
    portal = Portal.create!(account: account, name: 'CSP portal', slug: 'csp-portal-fixture')
    # A registered test host exercises the real public controller without external DNS setup.
    portal.update_column(:custom_domain, 'www.example.com') # rubocop:disable Rails/SkipsModelValidations
    previous_nonce = nil
    [{}, { 'Turbo-Frame' => 'search-results' }].each do |headers|
      manifest = ViteRuby.instance.manifest
      manifest.stub(:resolve_entries, { scripts: [], imports: [], stylesheets: [] }) do
        manifest.stub(:vite_client_src, nil) do
          get "/hc/#{portal.slug}/en/search", params: { query: '' }, headers: headers
        end
      end
      assert_response :success
      document = Nokogiri::HTML(response.body)
      assert_equal 'reload', document.at_css('meta[name="turbo-visit-control"]')&.[]('content'),
                   'Turbo must not attach a response nonce to an older document CSP'
      nonce = nonce_from(document)
      assert_equal nonce, document.at_css('meta[name="csp-nonce"]')['content']
      assert_includes response.headers['Content-Security-Policy'], Toybaco::ScriptPolicy.policy(nonce)
      refute_equal previous_nonce, nonce if previous_nonce
      previous_nonce = nonce
    end
  end

  def test_script_policy_intersects_existing_stricter_policy_and_preserves_body
    body = ['<html><head></head><body>fixture</body></html>']
    received = nil
    policy = Toybaco::ScriptPolicy.new(lambda { |env|
      received = env
      [200, { 'content-security-policy' => "script-src 'none'; frame-ancestors https://shop.example.test",
              'Content-Type' => 'text/html', 'ETag' => 'old-document', 'Cache-Control' => 'no-store' }, body]
    })
    env = { 'REQUEST_METHOD' => 'GET', 'HTTP_ACCEPT' => 'text/html', 'HTTP_IF_NONE_MATCH' => 'old',
            'HTTP_IF_MODIFIED_SINCE' => 'old', Toybaco::ScriptPolicy::NONCE_KEY => 'attacker' }
    status, headers, actual_body = policy.call(env)
    assert_equal 200, status
    assert_same body, actual_body
    assert_match(/\Ascript-src 'none'; frame-ancestors https:\/\/shop\.example\.test, script-src 'nonce-/, headers['Content-Security-Policy'])
    assert_equal 1, headers.keys.grep(/\Acontent-security-policy\z/i).length
    refute headers.key?('content-security-policy')
    refute headers.key?('ETag')
    assert_equal 'no-store', headers['Cache-Control']
    refute received.key?('HTTP_IF_NONE_MATCH')
    refute received.key?('HTTP_IF_MODIFIED_SINCE')
    refute_equal 'attacker', received[Toybaco::ScriptPolicy::NONCE_KEY]
  end

  def test_widget_frame_ancestors_and_nonce_match_actual_rendered_document
    account = Account.create!(name: 'CSP fixture')
    channel = Channel::WebWidget.create!(account: account, website_url: 'https://shop.example.test',
                                        allowed_domains: 'https://shop.example.test')
    Inbox.create!(account: account, channel: channel, name: 'CSP widget')
    manifest = ViteRuby.instance.manifest
    manifest.stub(:resolve_entries, { scripts: [], imports: [], stylesheets: [] }) do
      manifest.stub(:vite_client_src, nil) { get '/widget', params: { website_token: channel.website_token } }
    end
    assert_response :success
    nonce = nonce_from(Nokogiri::HTML(response.body))
    assert_includes response.headers['Content-Security-Policy'], 'frame-ancestors https://shop.example.test'
    assert_includes response.headers['Content-Security-Policy'], Toybaco::ScriptPolicy.policy(nonce)
  end

  def test_actual_sidekiq_web_templates_and_native_policy_use_the_outer_request_nonce
    previous_nonce = nil
    2.times do
      env = Rack::MockRequest.env_for('/', 'rack.session' => {}, 'HTTP_ACCEPT' => 'text/html')
      env['HTTP_X_CSP_NONCE'] = 'attacker'
      status, headers, body = Toybaco::ScriptPolicy.new(Sidekiq::Web.new).call(env)
      begin
        assert_equal 200, status
        html = +''
        body.each { |part| html << part }
        nonce = nonce_from(Nokogiri::HTML(html))
        assert_equal env.fetch(Toybaco::ScriptPolicy::NONCE_KEY), nonce
        assert_equal nonce, env[:csp_nonce]
        policy = headers.fetch('Content-Security-Policy')
        assert_includes policy, "script-src 'self' 'nonce-#{nonce}'"
        assert_includes policy, Toybaco::ScriptPolicy.policy(nonce)
        script_policies = policy.split(',').map { |part| part.split(';').find { |d| d.strip.start_with?('script-src ') } }
        assert script_policies.all? { |part| part && !part.include?('unsafe-inline') && !part.include?('unsafe-eval') }
        refute_equal previous_nonce, nonce if previous_nonce
        previous_nonce = nonce
      ensure
        body.close if body.respond_to?(:close)
      end
    end
    receiver_called = false
    receiver = Toybaco::ScriptPolicy::SidekiqNonce.new(->(_env) { receiver_called = true })
    assert_raises(ArgumentError) do
      receiver.call(Toybaco::ScriptPolicy::NONCE_KEY => 'attacker')
    end
    refute receiver_called
  end

  def test_missing_static_asset_is_enforced_and_conditional_nonce_cannot_disable_scripts_policy
    get '/vite/assets/toybaco-csp-absent.js'
    assert_response :not_found
    policy = response.headers.fetch('Content-Security-Policy')
    assert_match(/script-src 'nonce-[A-Za-z0-9+\/]{24}' 'strict-dynamic' 'self'/, policy)
    assert_includes policy, "script-src-attr 'none'"
    refute_includes policy, 'unsafe-inline'
    refute_includes policy, 'unsafe-eval'
  end

  def test_only_explicit_platform_script_config_receives_nonce_not_customer_html
    # Renderer bypasses middleware; Rails reads an existing nonce only when its
    # generator is present in request env. Bind the actual application generator.
    renderer = ApplicationController.renderer.new(
      Toybaco::ScriptPolicy::NONCE_KEY => 'abcdefghijklmnopqrstuvwx',
      'action_dispatch.content_security_policy_nonce_generator' =>
        Rails.application.config.content_security_policy_nonce_generator
    )
    html = renderer.render(inline: '<%= toybaco_dashboard_scripts_with_nonce %>', assigns: {
      dashboard_scripts: '<script src="https://analytics.example.test/a.js"></script><noscript>fallback</noscript>'
    })
    markup = Nokogiri::HTML.fragment(html)
    assert_equal 'abcdefghijklmnopqrstuvwx', markup.at_css('script')['nonce']
    assert_equal 'fallback', markup.at_css('noscript').text
    assert_equal 0, ToybacoCspHelper.instance_method(:toybaco_dashboard_scripts_with_nonce).arity
    assert_raises(ArgumentError) { Toybaco::ScriptPolicy.policy('attacker') }
  end

  def test_response_html_is_not_blanket_authorized
    untrusted = '<html><head><script>window.untrusted=true</script></head><body></body></html>'
    nonce = SecureRandom.base64(18)
    middleware = Toybaco::BrandInjector.new(lambda { |_env| [200, { 'Content-Type' => 'text/html' }, [untrusted]] })
    _status, _headers, body = middleware.call('PATH_INFO' => '/app/login',
      'action_dispatch.content_security_policy_nonce' => nonce)
    document = Nokogiri::HTML(body.join)
    assert_nil document.css('script').find { |script| script.text.include?('window.untrusted') }['nonce']
    assert_equal nonce, document.at_css('script[data-toybaco-post-config]')['nonce']
  end

  def test_untrusted_nonce_header_and_malformed_env_value_cannot_authorize_injected_markup
    middleware = Toybaco::BrandInjector.new(lambda { |_env| [200, { 'Content-Type' => 'text/html' }, ['<html><head></head><body></body></html>']] })
    _status, _headers, body = middleware.call('PATH_INFO' => '/app/login',
      'HTTP_X_CSP_NONCE' => 'attacker', 'action_dispatch.content_security_policy_nonce' => '\" onload=attacker')
    document = Nokogiri::HTML(body.join)
    assert_nil document.at_css('script[data-toybaco-post-config]')['nonce']
    assert_empty document.css('[onload]')
  end
end
