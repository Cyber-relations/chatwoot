# frozen_string_literal: true

# devise-two-factor 6.1.0 (Gemfile.lock) records the server's current time step after a match (consume_otp!),
# not the step the code belongs to. A code accepted early through the 30-second drift then passed again inside
# its own step. Record the step of the matched code and let verify(after:) alone decide: it rejects that code
# and every earlier one, and it accepts any later unused code, so a device 30 seconds ahead or behind signs in
# again with the next code it shows. Callers verify under the user's row lock (Mfa::AuthenticationService,
# enrollment).
module Toybaco::Security::TotpConsumption
  def validate_and_consume_otp!(code, options = {})
    secret = options[:otp_secret] || otp_secret
    return false unless code.present? && secret.present?

    totp = otp(secret)
    drift = self.class.otp_allowed_drift
    after = consumed_timestep * totp.interval if consumed_timestep
    matched_at = totp.verify(code.gsub(/\s+/, ''), drift_behind: drift, drift_ahead: drift, after: after)
    return false unless matched_at

    self.consumed_timestep = matched_at / totp.interval
    save!(validate: false)
    true
  end
end
