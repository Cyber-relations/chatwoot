# frozen_string_literal: true

module Toybaco::Security::WhatsappVerifyToken
  private

  def valid_token?(token)
    channel = Channel::Whatsapp.find_by(phone_number: params[:phone_number])
    expected = channel&.provider_config&.[]('webhook_verify_token')
    expected.present? && ActiveSupport::SecurityUtils.secure_compare(token.to_s, expected.to_s)
  end
end
