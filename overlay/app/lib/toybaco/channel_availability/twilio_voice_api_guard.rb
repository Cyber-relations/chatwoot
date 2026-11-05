# frozen_string_literal: true

module Toybaco::ChannelAvailability::TwilioVoiceApiGuard
  private

  def toybaco_voice_api_available
    return if Toybaco::ChannelAvailability.enabled?('voice')

    Rails.logger.warn('Toybaco API rejected: voice calls are not offered')
    head :not_found
  end
end
