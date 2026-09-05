# frozen_string_literal: true

require 'minitest/autorun'
require 'openssl'
require_relative '../overlay/app/lib/toybaco/agent_login'

# staging 専用エージェントログインのホストガードと token 契約。
# AWS / 本番秘密 / 平文 token は使わない。
class ChatwootAgentLoginTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  LOGIN = Toybaco::AgentLogin
  FIXTURE_TOKEN = 'toybaco-agent-login-test-double-token'
  FIXTURE_EMAIL = 'back.together0607+toybaco-e2e-admin-a@gmail.com'

  class MemoryStore
    def initialize
      @keys = {}
    end

    def set(key, value, not_exists:, expires_in:)
      raise 'nx/ex required' unless not_exists == true && expires_in.to_i.positive?
      return false if @keys.key?(key)

      @keys[key] = value
      true
    end
  end

  def env(overrides = {})
    {
      'FRONTEND_URL' => 'https://app.staging.toybaco.jp',
      'TOYBACO_AGENT_LOGIN' => '',
      'TOYBACO_AGENT_LOGIN_SECRET_JSON' => ''
    }.merge(overrides)
  end

  def secret_json(extra = {})
    { 'token' => FIXTURE_TOKEN, 'email' => FIXTURE_EMAIL, 'account_id' => 1 }.merge(extra).to_json
  end

  def test_constants_pin_staging_fixture_and_secret_name
    assert_equal 'app.staging.toybaco.jp', LOGIN::STAGING_HOST
    assert_equal 'app.toybaco.jp', LOGIN::PRODUCTION_HOST
    assert_equal '/toybaco/agent-login', LOGIN::PATH
    assert_equal 'toybaco/staging/e2e-admin-a', LOGIN::SECRET_ID
    assert_equal FIXTURE_EMAIL, LOGIN::DEFAULT_EMAIL
    assert_equal 1, LOGIN::DEFAULT_ACCOUNT_ID
    assert_equal :not_found, LOGIN.denied_status
  end

  def test_staging_host_is_enabled_even_when_rails_is_production
    assert LOGIN.enabled?(host: 'app.staging.toybaco.jp', rails_env: 'production', env: env)
  end

  def test_production_host_is_always_closed
    [
      ['app.toybaco.jp', 'production', env],
      ['app.toybaco.jp', 'development', env(LOGIN::ENABLE_ENV => '1')],
      ['app.toybaco.jp', 'test', env(LOGIN::ENABLE_ENV => '1')],
      ['APP.TOYBACO.JP', 'development', env(LOGIN::ENABLE_ENV => '1')]
    ].each do |host, rails_env, environment|
      refute LOGIN.enabled?(host: host, rails_env: rails_env, env: environment), host
    end
  end

  def test_production_frontend_url_is_always_closed
    production_frontend = env('FRONTEND_URL' => 'https://app.toybaco.jp')
    refute LOGIN.enabled?(
      host: 'app.staging.toybaco.jp',
      rails_env: 'production',
      env: production_frontend
    )
    refute LOGIN.enabled?(
      host: 'www.example.com',
      rails_env: 'test',
      env: production_frontend.merge(LOGIN::ENABLE_ENV => '1')
    )
  end

  def test_explicit_flag_allows_non_production_only
    assert LOGIN.enabled?(
      host: 'www.example.com',
      rails_env: 'test',
      env: env(LOGIN::ENABLE_ENV => '1')
    )
    refute LOGIN.enabled?(
      host: 'www.example.com',
      rails_env: 'production',
      env: env(LOGIN::ENABLE_ENV => '1')
    )
    refute LOGIN.enabled?(
      host: 'www.example.com',
      rails_env: 'test',
      env: env(LOGIN::ENABLE_ENV => '0')
    )
  end

  def test_unknown_hosts_are_closed
    %w[app.toybaco.test localhost 127.0.0.1 post.staging.toybaco.jp evil.example].each do |host|
      refute LOGIN.enabled?(host: host, rails_env: 'production', env: env), host
    end
  end

  def test_shared_token_matches_without_logging_material
    secret = LOGIN.parse_secret(secret_json)

    assert_equal :shared, LOGIN.authenticate_token(FIXTURE_TOKEN, secret)
    assert_nil LOGIN.authenticate_token('wrong-token-value-same-len!!', secret)
    assert_nil LOGIN.authenticate_token('', secret)
    assert_nil LOGIN.authenticate_token(nil, secret)
    refute_includes secret_json, 'password'
  end

  def test_signed_token_is_short_ttl_and_single_use
    secret = LOGIN.parse_secret(secret_json)
    now = 1_700_000_000
    exp = now + 120
    nonce = 'ab' * 16
    digest = OpenSSL::HMAC.hexdigest('SHA256', FIXTURE_TOKEN, "v1|#{exp}|#{nonce}")
    provided = "v1.#{exp}.#{nonce}.#{digest}"
    store = MemoryStore.new

    assert_equal :signed, LOGIN.authenticate_token(provided, secret, now: now)
    assert LOGIN.valid_signed_token?(provided, FIXTURE_TOKEN, now: now)
    refute LOGIN.valid_signed_token?(provided, FIXTURE_TOKEN, now: exp)
    assert LOGIN.consume!(provided, store: store)
    refute LOGIN.consume!(provided, store: store)
  end

  def test_load_secret_uses_test_double_json_not_aws
    called = false
    reader = lambda do |_id|
      called = true
      raise 'Secrets Manager must not be called when a test double is set'
    end
    secret = LOGIN.load_secret(
      env: env(LOGIN::SECRET_JSON_ENV => secret_json),
      reader: reader
    )

    assert_equal FIXTURE_TOKEN, secret['token']
    assert_equal FIXTURE_EMAIL, secret['email']
    assert_equal 1, secret['account_id']
    refute called
  end

  def test_load_secret_accepts_pretty_json_and_rejects_other_users
    pretty = <<~JSON
      {
        "token": "#{FIXTURE_TOKEN}",
        "email": "#{FIXTURE_EMAIL}",
        "account_id": 1
      }
    JSON
    secret = LOGIN.load_secret(env: env(LOGIN::SECRET_JSON_ENV => pretty), reader: ->(_) { raise 'aws' })
    assert_equal FIXTURE_TOKEN, secret['token']

    other = secret_json('email' => 'other@example.invalid')
    assert_nil LOGIN.parse_secret(other)
    assert_nil LOGIN.parse_secret(secret_json('account_id' => 99))
  end

  def test_controller_rejects_before_sign_in
    controller = File.read(File.join(ROOT, 'overlay/app/app/controllers/toybaco/agent_login_controller.rb'))
    initializer = File.read(File.join(ROOT, 'overlay/app/config/initializers/toybaco_agent_login.rb'))

    assert_includes controller, 'before_action :reject_unless_enabled'
    assert_includes controller, 'Toybaco::AgentLogin.enabled?'
    assert_includes controller, 'head Toybaco::AgentLogin.denied_status'
    assert_includes controller, '&.set_user(user, scope: :user)'
    assert_includes controller, 'User.from_email'
    assert_includes controller, "cookies[:cw_d_session_info]"
    assert_includes controller, 'httponly: false'
    assert_includes controller, "redirect_to '/app/'"
    refute_includes controller, 'puts '
    refute_match(/FIXTURE_TOKEN|sk_live|AKIA/, controller)
    assert_includes initializer, "get Toybaco::AgentLogin::PATH, to: 'toybaco/agent_login#show'"
    assert_includes initializer, "post Toybaco::AgentLogin::PATH, to: 'toybaco/agent_login#create'"
    assert_includes initializer, 'filter_parameters += [:token]'
  end

  def test_docs_explain_sm_usage_without_plaintext
    docs = File.read(File.join(ROOT, 'docs/staging-agent-login.md'))

    assert_includes docs, 'toybaco/staging/e2e-admin-a'
    assert_includes docs, 'aws secretsmanager get-secret-value'
    assert_includes docs, 'app.staging.toybaco.jp'
    assert_includes docs, 'app.toybaco.jp'
    assert_includes docs, 'TOYBACO_AGENT_LOGIN=1'
    refute_match(/AKIA[A-Z0-9]{16}/, docs)
    refute_includes docs, FIXTURE_TOKEN
  end
end
