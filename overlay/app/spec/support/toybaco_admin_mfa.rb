# frozen_string_literal: true

# Use the real password + single-use backup-code path in privileged request
# fixtures. Warden's sign_in helper intentionally does NOT manufacture MFA proof.
module ToybacoAdminMfaLoginHelper
  def sign_in_admin_with_mfa(user)
    code = SecureRandom.hex(4).upcase
    user.update!(otp_secret: User.generate_otp_secret, otp_required_for_login: true, otp_backup_codes: [code])
    post '/super_admin/sign_in', params: { super_admin: { email: user.email, password: 'Password1!', backup_code: code } }
    raise 'synthetic admin MFA login failed' unless response.redirect? && response.location.end_with?('/super_admin')
  end
end

RSpec.configure { |config| config.include ToybacoAdminMfaLoginHelper, type: :request } if defined?(RSpec)
