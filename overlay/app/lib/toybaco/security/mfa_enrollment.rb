# frozen_string_literal: true

module Toybaco::Security::MfaEnrollment
  module_function

  def password_proof(user)
    OpenSSL::HMAC.hexdigest('SHA256', Rails.application.secret_key_base, [user.id, user.email, user.encrypted_password, user.otp_secret].to_json)
  end

  def user(session)
    proof = session[:toybaco_mfa_enrollment]
    return unless proof.is_a?(Hash) && proof['expires_at'].to_i > Time.current.to_i

    user = User.find_by(id: proof['user_id'])
    return unless eligible?(user)
    return unless ActiveSupport::SecurityUtils.secure_compare(proof['password_proof'].to_s, password_proof(user))

    user
  end

  def eligible?(user)
    user&.active_for_authentication? && user.confirmed? && !user.mfa_enabled?
  end
end
