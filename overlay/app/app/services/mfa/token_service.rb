# frozen_string_literal: true

class Mfa::TokenService < BaseTokenService
  pattr_initialize [:user, :token]

  MFA_TOKEN_EXPIRY = 5.minutes
  PURPOSE = 'toybaco-dashboard-mfa-v1'

  def generate_token
    nonce = SecureRandom.hex(32)
    @payload = { user_id: user.id, purpose: PURPOSE, nonce: nonce, exp: MFA_TOKEN_EXPIRY.from_now.to_i,
                 fingerprint: Toybaco::Security::ApplicationMfaSession.fingerprint(user) }
    with_redis { |redis| redis.set(nonce_key(nonce), user.id.to_s, ex: MFA_TOKEN_EXPIRY.to_i) }
    super
  end

  def verify_token
    decoded = decode_token
    return unless valid_claims?(decoded)

    current = User.find_by(id: decoded[:user_id])
    return unless Toybaco::Security::ApplicationMfaSession.eligible?(current)
    return unless ActiveSupport::SecurityUtils.secure_compare(decoded[:fingerprint].to_s,
                                                              Toybaco::Security::ApplicationMfaSession.fingerprint(current))
    return unless with_redis { |redis| redis.get(nonce_key(decoded[:nonce])) } == current.id.to_s

    current
  end

  def consume!
    decoded = decode_token
    return false unless valid_claims?(decoded)

    with_redis { |redis| redis.del(nonce_key(decoded[:nonce])) } == 1
  end

  private

  def with_redis(&)
    $velma.with(&) # rubocop:disable Style/GlobalVars
  end

  def valid_claims?(decoded)
    decoded[:purpose] == PURPOSE && decoded[:nonce].to_s.match?(/\A[a-f0-9]{64}\z/)
  end

  def nonce_key(nonce)
    "toybaco:mfa-challenge:v1:#{nonce}"
  end
end
