# frozen_string_literal: true

module Toybaco::ChannelAvailability::WhatsappCallsGuard
  private

  def toybaco_whatsapp_calls_available
    return if Toybaco::ChannelAvailability.enabled?('whatsapp_call')

    Rails.logger.warn('Toybaco API rejected: whatsapp calls are not offered')
    head :not_found
  end
end
