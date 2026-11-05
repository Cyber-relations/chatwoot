# frozen_string_literal: true

module Toybaco::ChannelAvailability::WhatsappVoiceActivationGuard
  # Upstream contacts Meta before saving, so a save callback alone is too late.
  def enable_voice_calling!
    unless Toybaco::ChannelAvailability.enabled?('whatsapp_call')
      errors.add(:base, Toybaco::ChannelAvailability.error)
      # The calling API renders the exception message, including in locales
      # without ActiveRecord's generic record_invalid translation.
      raise ActiveRecord::RecordInvalid.new(self), Toybaco::ChannelAvailability.error
    end

    super
  end

  private

  def toybaco_voice_activation_available
    return if Toybaco::ChannelAvailability.enabled?('whatsapp_call')
    return if provider_config&.dig('calling_enabled').blank?
    return if provider_config_in_database&.dig('calling_enabled').present?

    errors.add(:base, Toybaco::ChannelAvailability.error)
    throw :abort
  end
end
