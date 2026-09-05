# frozen_string_literal: true

require 'json'
require_relative 'agent_login/helpers'
require_relative 'agent_login/redis_store'
require_relative 'agent_login/secrets_manager_reader'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  # staging 専用の E2E admin_a ワンショットログイン。
  # 本番ホスト・本番 FRONTEND_URL では必ず閉じる。秘密本文は返さない。
  module AgentLogin
    extend Helpers
    public_class_method :consume!, :load_secret, :valid_signed_token?

    STAGING_HOST = 'app.staging.toybaco.jp'
    PRODUCTION_HOST = 'app.toybaco.jp'
    PATH = '/toybaco/agent-login'
    SECRET_ID = 'toybaco/staging/e2e-admin-a'
    DEFAULT_EMAIL = 'back.together0607+toybaco-e2e-admin-a@gmail.com'
    DEFAULT_ACCOUNT_ID = 1
    ENABLE_ENV = 'TOYBACO_AGENT_LOGIN'
    SECRET_JSON_ENV = 'TOYBACO_AGENT_LOGIN_SECRET_JSON'
    SECRET_ID_ENV = 'TOYBACO_AGENT_LOGIN_SECRET_ID'
    TOKEN_HEADER = 'X-Toybaco-Agent-Login'
    REGION = 'ap-northeast-1'
    SIGNED_TTL = 900
    SIGNED_PREFIX = 'v1'
    USED_PREFIX = 'TOYBACO_AGENT_LOGIN_USED::'

    module_function

    def enabled?(host:, rails_env:, env: ENV)
      normalized = normalize_host(host)
      return false if production_host?(normalized) || production_frontend?(env)
      return true if normalized == STAGING_HOST || explicit_non_production?(rails_env, env)

      false
    end

    def production_host?(host)
      normalize_host(host) == PRODUCTION_HOST
    end

    def production_frontend?(env)
      env['FRONTEND_URL'].to_s.strip.delete_suffix('/') == "https://#{PRODUCTION_HOST}"
    end

    def explicit_non_production?(rails_env, env)
      env[ENABLE_ENV].to_s == '1' && rails_env.to_s != 'production'
    end

    def normalize_host(host)
      host.to_s.strip.downcase.split('%').first.to_s.split(':').first
    end

    def denied_status
      :not_found
    end

    def parse_secret(raw)
      parsed = decode_secret(raw)
      token, email, account_id = secret_identity(parsed)
      return unless fixture_identity?(token, email, account_id)

      { 'token' => token, 'email' => email, 'account_id' => account_id, 'one_shot' => one_shot?(parsed) }
    end

    def provided_token(params, headers)
      header = headers[TOKEN_HEADER] || headers['HTTP_X_TOYBACO_AGENT_LOGIN']
      present_string(params[:token] || params['token'] || header)
    end

    def authenticate_token(provided, secret, now: Time.now.to_i)
      return unless provided && secret

      expected = secret.fetch('token')
      return :shared if secure_match?(provided, expected)
      return :signed if valid_signed_token?(provided, expected, now: now)

      nil
    end
  end
end
