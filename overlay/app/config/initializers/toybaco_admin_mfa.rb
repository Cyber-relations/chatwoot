# frozen_string_literal: true

# Middleware is loaded before the reloadable lib namespaces are registered.
module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Security; end
end

require_relative '../../lib/toybaco/security/admin_mfa_session'
require_relative '../../lib/toybaco/security/admin_mfa_guard'
require_relative '../../lib/toybaco/security/rate_limit_store'

Rails.application.config.middleware.insert_after Warden::Manager, Toybaco::Security::AdminMfaGuard

Rack::Attack.cache.store = Toybaco::Security::RateLimitStore.new(redis: $velma, pool: false) # rubocop:disable Style/GlobalVars

# The upstream limiter reads a top-level email; the HTML form submits it under
# super_admin. Hash the normalized identifier and keep the existing IP limiter.
Rack::Attack.throttle('super_admin_login/ip', limit: 5, period: 5.minutes) do |request|
  path = Toybaco::Security::AdminMfaGuard.normalized_path(request.path)
  request.ip if path == '/super_admin/sign_in' && request.post?
end

Rack::Attack.throttle('super_admin_login/email', limit: 5, period: 15.minutes) do |request|
  path = Toybaco::Security::AdminMfaGuard.normalized_path(request.path)
  next unless path == '/super_admin/sign_in' && request.post?

  nested = ActionDispatch::Request.new(request.env).params['super_admin']
  next unless nested.is_a?(Hash) && nested['email'].is_a?(String)

  email = nested['email'].strip.downcase
  Digest::SHA256.hexdigest(email) if email.present?
end
