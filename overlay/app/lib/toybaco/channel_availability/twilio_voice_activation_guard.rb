# frozen_string_literal: true

module Toybaco::ChannelAvailability::TwilioVoiceActivationGuard
  private

  def toybaco_voice_activation_available
    return if Toybaco::ChannelAvailability.enabled?('voice')
    return unless voice_enabled? && will_save_change_to_voice_enabled?

    errors.add(:base, Toybaco::ChannelAvailability.error)
    throw :abort
  end
end
