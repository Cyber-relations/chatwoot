# frozen_string_literal: true

# Outside Warden so an authentication failure also expires HttpOnly cookies.
# Controllers mark only the staff session routes, never public widget routes.
class Toybaco::Security::BrowserCookieExpiry
  def initialize(app)
    @app = app
  end

  def call(env)
    status, headers, body = @app.call(env)
    expire_login_cookies(headers) if expire_login_cookies?(status, env)
    [status, headers, body]
  end

  private

  # 'toybaco.browser_keep_cookies': a response that must not change the login cookies (BrowserAuthentication::KEEP_COOKIES).
  def expire_login_cookies?(status, env)
    env['toybaco.browser_authentication'] && session_ended?(status, env) && !env['toybaco.browser_keep_cookies']
  end

  def session_ended?(status, env)
    (status == 401 && !env['toybaco.browser_authenticated']) || (env['toybaco.browser_logout'] && status == 404)
  end

  def expire_login_cookies(headers)
    %w[cw_d_session_info cw_d_authenticated].each do |name|
      Rack::Utils.delete_cookie_header!(headers, name, path: '/', secure: true, httponly: true, same_site: :lax)
    end
  end
end
