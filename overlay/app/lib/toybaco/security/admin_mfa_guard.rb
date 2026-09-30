# frozen_string_literal: true

# Covers all admin controllers AND the mounted Sidekiq Rack app, including
# sessions created before this protection was deployed.
class Toybaco::Security::AdminMfaGuard
  PUBLIC_PATHS = %w[/super_admin/sign_in /super_admin/sign_out /super_admin/logout].freeze

  def initialize(app)
    @app = app
  end

  def self.normalized_path(path)
    Rack::Utils.unescape_path(path).squeeze('/').delete_suffix('/').sub(%r{\.[^/]+\z}, '')
  end

  def call(env)
    path = self.class.normalized_path(env.fetch('PATH_INFO', ''))
    return @app.call(env) unless path.match?(%r{\A/(super_admin|monitoring)(/|\z)})

    warden = env['warden']
    user = warden&.user(:super_admin)
    session = env['rack.session']
    return protected_response(env) if session && Toybaco::Security::AdminMfaSession.valid?(session, user)

    clear_unverified_session(session, warden)
    return protected_response(env) if PUBLIC_PATHS.include?(path)

    login_redirect(env)
  rescue Redis::BaseError, ConnectionPool::TimeoutError
    [503, { 'cache-control' => 'no-store', 'content-type' => 'text/plain' }, ['Authentication is temporarily unavailable.']]
  end

  private

  def protected_response(env)
    status, headers, body = @app.call(env)
    [status, headers.merge('cache-control' => 'private, no-store'), body]
  end

  def login_redirect(env)
    status = %w[GET HEAD].include?(env['REQUEST_METHOD']) ? 302 : 303
    [status, { 'location' => '/super_admin/sign_in', 'cache-control' => 'no-store', 'content-type' => 'text/plain' }, ['']]
  end

  def clear_unverified_session(session, warden)
    return unless session

    Toybaco::Security::AdminMfaSession.revoke!(session)
    warden&.logout(:super_admin)
  end
end
