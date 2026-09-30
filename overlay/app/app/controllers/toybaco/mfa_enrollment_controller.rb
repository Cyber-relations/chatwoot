# frozen_string_literal: true

class Toybaco::MfaEnrollmentController < ActionController::Base # rubocop:disable Rails/ApplicationController
  include Toybaco::Security::BrowserAuthentication
  layout 'toybaco_mfa_enrollment'
  protect_from_forgery with: :exception
  before_action :protect_enrollment
  before_action :limit_verification, only: :verify

  def show; end

  def create
    @user.with_lock do
      return expired unless Toybaco::Security::MfaEnrollment.user(session)&.id == @user.id

      @user.enable_two_factor! if @user.otp_secret.blank?
      session[:toybaco_mfa_enrollment]['password_proof'] = Toybaco::Security::MfaEnrollment.password_proof(@user)
    end
    render :show
  end

  def verify
    @user.with_lock do
      return expired unless Toybaco::Security::MfaEnrollment.user(session)&.id == @user.id
      return invalid_code unless @user.otp_secret.present? && @user.validate_and_consume_otp!(params[:otp_code].to_s)

      @backup_codes = @user.mfa_service.verify_and_activate!
      payload = @user.create_new_auth_token
      Toybaco::Security::ApplicationMfaSession.mark!(@user, payload.fetch('client'))
      @user.save!
      write_toybaco_browser_cookie(@user.id, payload)
      reset_session
    end
    render :complete
  end

  def cancel
    reset_session
    redirect_to '/app/login'
  end

  private

  def protect_enrollment
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Referrer-Policy'] = 'no-referrer'
    return head :forbidden unless request.get? || valid_enrollment_csrf?

    @user = Toybaco::Security::MfaEnrollment.user(session)
    expired unless @user
  end

  def valid_enrollment_csrf?
    request.headers['Origin'] == request.base_url &&
      [nil, '', 'same-origin'].include?(request.headers['Sec-Fetch-Site']) &&
      valid_authenticity_token?(session, request.headers['X-CSRF-Token'] || params[:authenticity_token])
  end

  def expired
    reset_session
    redirect_to '/app/login'
  end

  def invalid_code
    @error = '確認コードを確認して、もう一度入力してください。'
    render :show, status: :unprocessable_entity
  end

  def limit_verification
    store = Toybaco::Security::RateLimitStore.new(redis: $velma, pool: false) # rubocop:disable Style/GlobalVars
    count = store.increment("toybaco:mfa-enrollment-attempts:#{@user.id}", 1, expires_in: 10.minutes)
    head :too_many_requests if !count || count > 10
  rescue Redis::BaseError, ConnectionPool::TimeoutError
    head :service_unavailable
  end
end
