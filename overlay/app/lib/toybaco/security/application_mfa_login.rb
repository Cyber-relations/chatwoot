# frozen_string_literal: true

module Toybaco::Security::ApplicationMfaLogin
  # Raised when another request removed the SSO token after this request validated it.
  SsoTokenUsed = Class.new(StandardError)

  def create
    return super if mfa_verification_request?

    user = sso_authentication_request? ? @resource : find_user_for_authentication
    return super unless enrollment_required?(user)

    begin_enrollment(user)
  rescue SsoTokenUsed
    # The duplicate that lost may answer after the winner's 200 in the same browser: leave its login cookies alone.
    request.env[Toybaco::Security::BrowserAuthentication::KEEP_COOKIES] = true
    render_create_error_bad_credentials
  rescue Redis::BaseError, ConnectionPool::TimeoutError
    render json: { error: 'authentication_temporarily_unavailable' }, status: :service_unavailable
  end

  private

  def enrollment_required?(user)
    user && Toybaco::Security::ApplicationMfaSession.required?(user) && !user.mfa_enabled?
  end

  def begin_enrollment(user)
    return render_mfa_error('errors.mfa.invalid_token', :unauthorized) unless user.active_for_authentication? && user.confirmed?

    claim_sso_auth_token!(user) if sso_authentication_request?
    clear_toybaco_browser_cookie if toybaco_browser_request?
    reset_session
    session[:toybaco_mfa_enrollment] = {
      'user_id' => user.id, 'expires_at' => 5.minutes.from_now.to_i,
      'password_proof' => enrollment_password_proof(user)
    }
    render json: { mfa_enrollment_required: true, enrollment_path: '/toybaco/mfa-enrollment' }, status: :partial_content
  end

  def handle_mfa_required(user)
    clear_toybaco_browser_cookie if toybaco_browser_request?
    super
  end

  def handle_sso_authentication
    return render_mfa_error('errors.mfa.invalid_token', :unauthorized) unless @resource.active_for_authentication? && @resource.confirmed?
    return super unless @resource.mfa_enabled?

    claim_sso_auth_token!(@resource)
    handle_mfa_required(@resource)
  end

  # Upstream checks the SSO token with GET and deletes it only after issuing the session, without looking at the
  # result, so two requests with one token both signed in. DEL reports how many keys it removed: only the request
  # that removed the token goes on to a session or an MFA challenge. Upstream's later delete then removes nothing.
  def authenticate_resource_with_sso_token
    claim_sso_auth_token!(@resource)
    super
  end

  # Upstream's session limit runs before the SSO sign-in and may revoke (revoke_all_sessions / revoke_session_id)
  # or evict devices. Claim the token first, so a request that lost it changes no device before its 401.
  # The 409 session picker changes nothing and keeps the token for the retry.
  def revoke_sessions_for_login(user)
    claim_sso_auth_token!(user) if sso_sign_in_request?
    super
  end

  def evict_oldest_session(user)
    claim_sso_auth_token!(user) if sso_sign_in_request?
    super
  end

  def sso_sign_in_request?
    sso_authentication_request? && !mfa_verification_request?
  end

  def claim_sso_auth_token!(user)
    return if @toybaco_sso_auth_token_claimed
    raise SsoTokenUsed unless user.invalidate_sso_auth_token(params[:sso_auth_token]).to_i == 1

    @toybaco_sso_auth_token_claimed = true
  end

  def handle_mfa_verification
    challenge = Mfa::TokenService.new(token: params[:mfa_token])
    user = challenge.verify_token
    return render_mfa_error('errors.mfa.invalid_token', :unauthorized) unless user

    user.with_lock do
      return render_mfa_error('errors.mfa.invalid_token', :unauthorized) unless challenge.verify_token&.id == user.id

      authenticated = Mfa::AuthenticationService.new(user: user, otp_code: params[:otp_code], backup_code: params[:backup_code]).authenticate
      return render_mfa_error('errors.mfa.invalid_code') unless authenticated
      return render_mfa_error('errors.mfa.invalid_token', :unauthorized) unless challenge.consume!

      sign_in_mfa_user(user)
    end
  end

  def sign_in_mfa_user(user)
    evict_oldest_session(user) if sessions_limit_reached?(user)
    @resource = user
    @token = @resource.create_token
    Toybaco::Security::ApplicationMfaSession.mark!(@resource, @token.client)
    @resource.save!
    sign_in(:user, @resource, store: false, bypass: false)
    render_create_success
  end

  def enrollment_password_proof(user)
    Toybaco::Security::MfaEnrollment.password_proof(user)
  end
end
