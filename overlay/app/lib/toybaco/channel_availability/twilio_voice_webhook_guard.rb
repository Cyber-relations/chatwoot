# frozen_string_literal: true

module Toybaco::ChannelAvailability::TwilioVoiceWebhookGuard
  private

  def toybaco_voice_available
    return if Toybaco::ChannelAvailability.enabled?('voice')

    Rails.logger.warn('Toybaco webhook rejected: voice channel is not offered')
    head :not_found
  end
end
