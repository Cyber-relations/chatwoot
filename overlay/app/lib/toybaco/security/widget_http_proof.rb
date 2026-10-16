# frozen_string_literal: true

module Toybaco::Security::WidgetHttpProof
  def proof
    timestamp = Time.current.to_i
    nonce = SecureRandom.hex(16)
    payload = "#{record.id}:#{record.inbox_id}:#{record.link_digest}:#{timestamp}:#{nonce}"
    "tbwp1.#{timestamp}.#{nonce}.#{self.class.mac(payload)}"
  end

  def valid_proof?(value, allow_expired: false)
    parts = proof_parts(value)
    return false unless parts && record.current?

    timestamp, nonce, signature = parts
    return false unless proof_fresh?(timestamp, allow_expired)

    expected = self.class.mac("#{record.id}:#{record.inbox_id}:#{record.reload.link_digest}:#{timestamp}:#{nonce}")
    ActiveSupport::SecurityUtils.secure_compare(expected, signature)
  end

  private

  def proof_parts(value)
    match = /\Atbwp1\.([0-9]{10})\.([a-f0-9]{32})\.([a-f0-9]{64})\z/.match(value.to_s)
    match&.captures
  end

  def proof_fresh?(timestamp, allow_expired)
    timestamp.to_i <= Time.current.to_i && (allow_expired || timestamp.to_i >= Toybaco::Security::WidgetHttpSession::PROOF_TTL.ago.to_i)
  end
end
