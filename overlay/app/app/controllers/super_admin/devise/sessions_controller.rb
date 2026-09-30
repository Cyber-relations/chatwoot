# frozen_string_literal: true

class SuperAdmin::Devise::SessionsController < Devise::SessionsController
  protect_from_forgery with: :exception, prepend: true

  def new
    self.resource = resource_class.new
  end

  def create
    @super_admin = SuperAdmin.from_email(credentials[:email].to_s.strip.downcase)
    return reject_login unless valid_password?
    return reject_login('管理画面を開く前に、トイバコのプロフィールで二段階認証を設定してください。') unless @super_admin.mfa_enabled?

    authenticated = @super_admin.with_lock { verify_second_factor }
    return reject_login unless authenticated

    Toybaco::Security::AdminMfaSession.revoke!(session)
    reset_session
    Toybaco::Security::AdminMfaSession.issue!(session, @super_admin)
    sign_in(:super_admin, @super_admin)
    flash.discard
    redirect_to super_admin_root_path
  end

  def destroy
    Toybaco::Security::AdminMfaSession.revoke!(session)
    sign_out(:super_admin)
    reset_session
    redirect_to '/'
  end

  private

  def credentials
    value = params[:super_admin]
    return ActionController::Parameters.new unless value.is_a?(ActionController::Parameters)

    value.permit(:email, :password, :otp_code, :backup_code)
  end

  def valid_password?
    @super_admin&.active_for_authentication? && @super_admin.valid_password?(credentials[:password].to_s)
  end

  def verify_second_factor
    return false unless valid_password? && @super_admin.mfa_enabled? && @super_admin.otp_secret.present?

    Mfa::AuthenticationService.new(user: @super_admin, otp_code: credentials[:otp_code].to_s.strip,
                                   backup_code: credentials[:backup_code].to_s.strip.upcase).authenticate
  end

  def reject_login(message = 'メールアドレス、パスワード、確認コードを確認してください。')
    redirect_to super_admin_session_path, flash: { error: message }
  end
end
