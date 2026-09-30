# frozen_string_literal: true

require 'digest'
require 'securerandom'

# A Rails login cookie alone is not evidence that the second factor was
# verified. Keep a revocable, time-limited proof on the server as well.
module Toybaco::Security::AdminMfaSession
  KEY = 'toybaco_admin_mfa'
  LIFETIME = 12.hours.to_i

  module_function

  def issue!(session, user)
    revoke!(session)
    nonce = SecureRandom.hex(32)
    proof = { 'nonce' => nonce, 'user_id' => user.id, 'issued_at' => Time.current.to_i }
    Redis::Alfred.setex(redis_key(nonce), fingerprint(user), LIFETIME)
    session[KEY] = proof
  end

  def valid?(session, user)
    return false unless eligible?(user)

    proof = session[KEY]
    return false unless current_proof?(proof, user)

    stored = Redis::Alfred.get(redis_key(proof['nonce']))
    stored.present? && ActiveSupport::SecurityUtils.secure_compare(stored, fingerprint(user))
  end

  def eligible?(user)
    user.is_a?(SuperAdmin) && user.active_for_authentication? && user.mfa_enabled? && user.otp_secret.present?
  end

  def current_proof?(proof, user)
    proof.is_a?(Hash) && proof['user_id'] == user.id && valid_nonce?(proof['nonce']) &&
      proof['issued_at'].is_a?(Integer) && (0...LIFETIME).cover?(Time.current.to_i - proof['issued_at'])
  end

  def revoke!(session)
    proof = session.delete(KEY)
    Redis::Alfred.delete(redis_key(proof['nonce'])) if proof.is_a?(Hash) && valid_nonce?(proof['nonce'])
  end

  def valid_nonce?(nonce)
    nonce.is_a?(String) && nonce.match?(/\A[0-9a-f]{64}\z/)
  end

  def redis_key(nonce)
    "toybaco:admin_mfa:v1:#{nonce}"
  end

  def fingerprint(user)
    Digest::SHA256.hexdigest([user.id, user.encrypted_password, user.otp_secret].join("\0"))
  end
end
