# frozen_string_literal: true

# Outside Warden so an authentication failure also expires HttpOnly cookies.
# Controllers mark only the staff session routes, never public widget routes.
class Toybaco::Security::BrowserCookieExpiry
  def initialize(app)
    @app = app
  end

  def call(env)
    status, headers, body = @app.call(env)
    ended = (status == 401 && !env['toybaco.browser_authenticated']) || (env['toybaco.browser_logout'] && status == 404)
    if env['toybaco.browser_authentication'] && ended
      %w[cw_d_session_info cw_d_authenticated].each do |name|
        Rack::Utils.delete_cookie_header!(headers, name, path: '/', secure: true, httponly: true, same_site: :lax)
      end
    end
    [status, headers, body]
  end
end
