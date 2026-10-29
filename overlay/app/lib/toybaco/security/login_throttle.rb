# frozen_string_literal: true

require 'digest/sha2'

# Upstream's four POST /auth/sign_in throttles read Rack::Request#params, which never parses a JSON body.
# The dashboard sends both sign-in steps as JSON, so the MFA step ({mfa_token, otp_code}) was counted as a
# password attempt, never reached the two MFA throttles, and gave login/email an empty discriminator that every
# user's MFA step shared (10 per 15 minutes for everyone). These rules keep the names, limits and periods and read
# the request the way DeviseOverrides::SessionsController does: ActionDispatch parameters (JSON included), the
# `email` header when no email parameter is sent, and the router's path normalization.
module Toybaco::Security::LoginThrottle
  PATH = '/auth/sign_in'
  PARAMS_ENV = 'toybaco.login_throttle.params'

  module_function

  def register!
    Rack::Attack.throttle('login/ip', limit: 5, period: 5.minutes) do |request|
      request.ip if password_step?(request)
    end
    Rack::Attack.throttle('login/email', limit: 10, period: 15.minutes) do |request|
      email_key(request) if password_step?(request)
    end
    Rack::Attack.throttle('mfa_login/ip', limit: 10, period: 1.minute) do |request|
      request.ip if mfa_step?(request)
    end
    Rack::Attack.throttle('mfa_login/token', limit: 10, period: 1.minute) do |request|
      token_key(request) if mfa_step?(request)
    end
  end

  # The controller takes the MFA branch whenever params[:mfa_token] is present; such a request never checks a password.
  def mfa_step?(request)
    params = sign_in_params(request)
    params.is_a?(Hash) && params['mfa_token'].present?
  end

  def password_step?(request)
    params = sign_in_params(request)
    params.is_a?(Hash) && params['mfa_token'].blank?
  end

  # Same identity as the controller: params[:email] ||= headers['email'] (nil and false both fall back), then
  # strip.downcase. Removing the remaining whitespace only merges buckets. Requests without a usable email are left
  # to login/ip instead of one shared bucket.
  def email_key(request)
    email = sign_in_params(request)['email']
    email ||= request.get_header('HTTP_EMAIL')
    return unless email.is_a?(String)

    normalized = email.dup.force_encoding(Encoding::UTF_8).scrub.strip.downcase.gsub(/\s+/, '')
    Digest::SHA256.hexdigest(normalized) if normalized.present?
  end

  # jwt 2.10.3 checks the signature over the header and payload segments exactly as sent, but decodes the
  # signature segment leniently (whitespace, padding, either base64 alphabet), so one challenge has many accepted
  # spellings. Its signed part (the first two segments) is the same for all of them and differs between challenges.
  def token_key(request)
    token = sign_in_params(request)['mfa_token']
    return unless token.is_a?(String)

    signed = token.split('.').first(2).join('.')
    Digest::SHA256.hexdigest(signed) if signed.present?
  end

  # nil for every other request. Parameters are parsed only for POST /auth/sign_in (upstream's guard against
  # encoding errors on unrelated endpoints); a body the controller cannot parse either is treated as a password step
  # without an email, so login/ip still counts it and the controller rejects it as before.
  def sign_in_params(request)
    return unless request.post? && sign_in_path?(request.path)

    request.env[PARAMS_ENV] ||= begin
      ActionDispatch::Request.new(request.env).params
    rescue ActionController::BadRequest, ActionDispatch::Http::Parameters::ParseError, ActionDispatch::Http::MimeNegotiation::InvalidType
      {}
    end
  end

  # Journey squeezes repeated slashes and drops a trailing one before routing, and the route takes a format
  # extension, so //auth/sign_in, /auth/sign_in/ and /auth/sign_in.json all reach the same action.
  def sign_in_path?(path)
    normalized = path.b.squeeze('/')[/\A[^.]*/]
    normalized.delete_suffix('/') == PATH
  end
end
