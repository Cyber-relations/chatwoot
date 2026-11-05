# frozen_string_literal: true

class Toybaco::Security::AttachmentTransferCors
  PREFLIGHT_VARY = 'Origin, Access-Control-Request-Method, Access-Control-Request-Headers'

  # Match pinned upstream config/initializers/cors.rb for /api/* reservations.
  # These modes allow every origin without credentials; otherwise none do.
  def self.enabled?
    Rails.env.development? || %w[CW_API_ONLY_SERVER ENABLE_API_CORS].any? do |name|
      ActiveModel::Type::Boolean.new.cast(ENV.fetch(name, false))
    end
  end

  def initialize(enabled: self.class.enabled?)
    @enabled = enabled
  end

  def preflight(env)
    return preflight_response(405) unless origin?(env) && env['HTTP_ACCESS_CONTROL_REQUEST_METHOD'] == 'PUT'
    return preflight_response(403) unless @enabled && allowed_headers?(env)

    preflight_response(204, 'access-control-allow-origin' => '*', 'access-control-allow-methods' => 'PUT',
                            'access-control-allow-headers' => 'Content-Type')
  end

  def decorate(response, env)
    status, headers, body = response
    # The upstream API-only/development wildcard also matches this path. Do
    # not let it widen this resource's methods, headers or credential policy.
    headers = headers.reject { |name, _value| name.downcase.start_with?('access-control-') }
    headers['access-control-allow-origin'] = '*' if @enabled && origin?(env)
    [status, headers, body]
  end

  private

  def origin?(env)
    !env['HTTP_ORIGIN'].to_s.empty?
  end

  def allowed_headers?(env)
    headers = env['HTTP_ACCESS_CONTROL_REQUEST_HEADERS'].to_s
    return true if headers.empty?

    headers.split(',', -1).all? { |header| header.strip.downcase == 'content-type' }
  end

  def preflight_response(status, headers = {})
    [status, { 'vary' => PREFLIGHT_VARY, 'cache-control' => 'no-store' }.merge(headers), []]
  end
end
