# frozen_string_literal: true

# Browser sessions keep the DTA credential in a server-issued HttpOnly cookie.
# Native clients without browser credentials retain explicit token-header auth.
module Toybaco::Security::BrowserAuthentication
  COOKIE = 'cw_d_session_info'
  MARKER = 'cw_d_authenticated'
  AUTH_HEADERS = %w[access-token token-type client expiry uid authorization api_access_token].freeze

  def toybaco_browser_request?
    request.cookies.key?(COOKIE) || request.headers['X-Toybaco-Browser'] == '1' ||
      request.headers['Origin'].present? || request.headers['Sec-Fetch-Site'].present?
  end

  def prepare_toybaco_browser_authentication
    return unless toybaco_browser_auth_path? && toybaco_browser_request?

    request.env['toybaco.browser_authentication'] = true
    request.env['toybaco.browser_logout'] = toybaco_logout?
    response.headers['Cache-Control'] = 'no-store'
    unless toybaco_safe_method? || toybaco_valid_csrf?
      render json: { error: 'csrf_verification_failed' }, status: :forbidden
      return
    end
    copy_toybaco_cookie_to_request
  end

  def set_user_by_token(mapping = nil)
    user = super
    request.env['toybaco.browser_authenticated'] = true if user && @token&.client
    user
  end

  def update_auth_header
    super
    return unless toybaco_browser_auth_path? && toybaco_browser_request?

    if (response.status == 401 && !request.env['toybaco.browser_authenticated']) || toybaco_logout?
      clear_toybaco_browser_cookie
    else
      publish_toybaco_browser_cookie
    end
    AUTH_HEADERS.each { |name| response.headers.delete(name) }
  end

  # Account signup uses AuthHelper rather than the DTA session controller.
  def publish_toybaco_direct_auth_headers(user, payload)
    return unless toybaco_browser_auth_path? && toybaco_browser_request?

    write_toybaco_browser_cookie(user.id, payload)
    AUTH_HEADERS.each { |name| response.headers.delete(name) }
  end

  private

  def toybaco_browser_auth_path?
    is_a?(Api::BaseController) || is_a?(Api::V1::Accounts::Conversations::DirectUploadsController) ||
      request.path_parameters[:controller].to_s.start_with?('devise_overrides/')
  end

  def toybaco_logout?
    request.path_parameters[:controller] == 'devise_overrides/sessions' && request.path_parameters[:action] == 'destroy'
  end

  def toybaco_safe_method?
    request.get? || request.head? || request.options?
  end

  def toybaco_valid_csrf?
    # Explicit verification cannot inherit the upstream CSRF skip or test-mode
    # exemption. SameSite is an additional constraint, not the CSRF mechanism.
    request.headers['Origin'] == request.base_url &&
      [nil, '', 'same-origin'].include?(request.headers['Sec-Fetch-Site']) &&
      valid_authenticity_token?(session, request.headers['X-CSRF-Token'])
  end

  def copy_toybaco_cookie_to_request
    # Never mix an ambient cookie with token headers or query parameters.
    AUTH_HEADERS.each do |name|
      request.headers[name] = nil
      params.delete(name)
    end
    payload = JSON.parse(request.cookies[COOKIE].to_s)
    return unless payload.is_a?(Hash)

    %w[access-token client uid].each do |name|
      value = payload[name]
      request.headers[name] = value if value.is_a?(String) && value.present?
    end
  rescue JSON::ParserError
    nil
  end

  def publish_toybaco_browser_cookie
    return unless response.headers['access-token'].present? && @resource && @token&.client

    # DTA has validated the live server record before returning these headers.
    # Never promote an unvalidated request cookie.
    payload = response.headers.slice(*AUTH_HEADERS).except('authorization')
    write_toybaco_browser_cookie(@resource.id, payload)
  end

  def write_toybaco_browser_cookie(user_id, payload)
    expiry = payload['expiry'].to_i
    return unless expiry > Time.current.to_i

    options = { expires: Time.at(expiry).utc, secure: true, same_site: :lax, path: '/' }
    cookies[COOKIE] = options.merge(value: payload.to_json, httponly: true)
    cookies[MARKER] = options.merge(value: toybaco_session_marker(user_id, payload['client']), httponly: false)
  end

  def toybaco_session_marker(user_id, client)
    Digest::SHA256.hexdigest([user_id, client].to_json)
  end

  def clear_toybaco_browser_cookie
    [COOKIE, MARKER].each do |name|
      cookies.delete(name, path: '/', secure: true, same_site: :lax)
    end
  end
end
