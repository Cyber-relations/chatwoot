# frozen_string_literal: true

module Toybaco::Security::WhatsappSignatureRequired
  private

  def verify_meta_signature!
    return super unless whatsapp_channel&.provider == 'default'

    # 360dialog does not use Meta's signing contract. Do not manufacture one.
    Rails.logger.warn('WhatsApp webhook rejected: 360dialog signing contract is not configured')
    head :unauthorized
  end

  def meta_signature_verification_required?
    true
  end
end
