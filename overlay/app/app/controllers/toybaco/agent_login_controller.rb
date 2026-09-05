# frozen_string_literal: true

# staging の E2E admin_a を Devise/Warden + DTA cookie でログインさせる。
# 本番ホストでは 404。token 本文はログに出さない。
class Toybaco::AgentLoginController < ActionController::Base # rubocop:disable Rails/ApplicationController
  skip_forgery_protection
  before_action :set_no_cache
  before_action :reject_unless_enabled

  def show
    establish_session
  end

  def create
    establish_session
  end

  private

  def reject_unless_enabled
    return if Toybaco::AgentLogin.enabled?(
      host: request.host,
      rails_env: Rails.env,
      env: ENV
    )

    head Toybaco::AgentLogin.denied_status
  end

  def establish_session
    secret = Toybaco::AgentLogin.load_secret
    provided = Toybaco::AgentLogin.provided_token(params, request.headers)
    kind = Toybaco::AgentLogin.authenticate_token(provided, secret)
    return head Toybaco::AgentLogin.denied_status unless kind

    return head Toybaco::AgentLogin.denied_status if (kind == :signed || secret['one_shot']) && !Toybaco::AgentLogin.consume!(provided)

    user = resolve_admin(secret)
    return head Toybaco::AgentLogin.denied_status unless user

    sign_in_browser_session!(user)
    Rails.logger.info("[toybaco-agent-login] session established user_id=#{user.id}")
    redirect_to '/app/', status: :see_other
  end

  def resolve_admin(secret)
    email = secret.fetch('email')
    account_id = secret.fetch('account_id')
    user = User.from_email(email)
    return unless user&.confirmed?

    membership = user.account_users.find_by(account_id: account_id)
    return unless membership&.administrator?

    user
  end

  def sign_in_browser_session!(user)
    request.env['warden']&.set_user(user, scope: :user)

    headers = user.create_new_auth_token
    cookies[:cw_d_session_info] = {
      value: {
        'access-token' => headers['access-token'],
        'client' => headers['client'],
        'uid' => headers['uid'],
        'expiry' => headers['expiry'],
        'token-type' => headers['token-type']
      }.to_json,
      expires: cookie_expiry(headers['expiry']),
      httponly: false,
      secure: true,
      same_site: :lax,
      path: '/'
    }
  end

  def cookie_expiry(expiry)
    timestamp = expiry.to_i
    return 2.months.from_now unless timestamp.positive?

    Time.at(timestamp).utc
  end

  def set_no_cache
    response.headers['Cache-Control'] = 'no-store'
  end
end
