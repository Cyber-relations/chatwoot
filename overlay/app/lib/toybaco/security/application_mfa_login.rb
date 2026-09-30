# frozen_string_literal: true

module Toybaco::Security::ApplicationMfaLogin
  def create
    return super if mfa_verification_request?

    user = sso_authentication_request? ? @resource : find_user_for_authentication
    return super unless enrollment_required?(user)

    begin_enrollment(user)
  rescue Redis::BaseError, ConnectionPool::TimeoutError
    render json: { error: 'authentication_temporarily_unavailable' }, status: :service_unavailable
  end

  private

  def enrollment_required?(user)
    user && Toybaco::Security::ApplicationMfaSession.required?(user) && !user.mfa_enabled?
  end

  def begin_enrollment(user)
    return render_mfa_error('errors.mfa.invalid_token', :unauthorized) unless user.active_for_authentication? && user.confirmed?

    user.invalidate_sso_auth_token(params[:sso_auth_token]) if sso_authentication_request?
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

    @resource.invalidate_sso_auth_token(params[:sso_auth_token])
    handle_mfa_required(@resource)
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
