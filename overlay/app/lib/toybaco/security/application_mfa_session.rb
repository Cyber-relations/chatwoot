# frozen_string_literal: true

# MFA proof belongs to a revocable DTA device record, not to a browser flag or
# merely to the user's enrollment state. Role changes are checked on every use.
module Toybaco::Security::ApplicationMfaSession
  # A verified dashboard device stays verified for 30 days (owner decision, 2026-10-05).
  # TOYBACO_APPLICATION_MFA_MAX_AGE_HOURS (whole hours 1-720, surrounding whitespace ignored) can shorten it;
  # a blank value keeps 30 days and any other value, including non-ASCII bytes, falls back to 12 hours.
  DEFAULT_MAX_AGE = 30.days
  STRICT_MAX_AGE = 12.hours

  module_function

  def required?(user)
    user.is_a?(SuperAdmin) || user.mfa_enabled? || user.account_users.exists?(role: 1)
  end

  def fingerprint(user)
    material = [user.id, user.encrypted_password, user.email, user.otp_secret, user.otp_required_for_login].to_json
    OpenSSL::HMAC.hexdigest('SHA256', Rails.application.secret_key_base, material)
  end

  def mark!(user, client)
    user.tokens.fetch(client).merge!('toybaco_mfa_at' => Time.current.to_i, 'toybaco_mfa_proof' => fingerprint(user))
  end

  def valid?(user, client)
    return true unless required?(user)
    return false unless eligible?(user)

    record = user.tokens[client]
    return false unless record.is_a?(Hash)

    verified_at = record['toybaco_mfa_at'].to_i
    age = Time.current.to_i - verified_at
    age >= 0 && age < max_age.to_i &&
      ActiveSupport::SecurityUtils.secure_compare(record['toybaco_mfa_proof'].to_s, fingerprint(user))
  end

  def max_age
    hours = ENV.fetch('TOYBACO_APPLICATION_MFA_MAX_AGE_HOURS', '')
    return STRICT_MAX_AGE unless hours.ascii_only?

    hours = hours.strip
    return DEFAULT_MAX_AGE if hours.empty?
    return STRICT_MAX_AGE unless hours.match?(/\A\d{1,3}\z/) && hours.to_i.between?(1, DEFAULT_MAX_AGE.in_hours)

    hours.to_i.hours
  end

  def eligible?(user)
    user&.mfa_enabled? && user.active_for_authentication? && user.confirmed?
  end

  module TokenValidation
    def valid_token?(token, client = 'default')
      super && Toybaco::Security::ApplicationMfaSession.valid?(self, client)
    end
  end

  module ReaderValidation
    def record_digest(user, client)
      return unless user && Toybaco::Security::ApplicationMfaSession.valid?(user, client)

      super
    end
  end

  module SingleUseVerification
    def authenticate
      return false unless user

      user.with_lock { super }
    end
  end
end
