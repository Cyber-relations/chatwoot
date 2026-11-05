# frozen_string_literal: true

module Toybaco::ChannelAvailability::InboxProviderGuard
  ACTIONS = %i[update register_webhook health sync_templates whatsapp_business_management_token].freeze
  ENTERPRISE_ACTIONS = %i[enable_whatsapp_calling disable_whatsapp_calling set_inbound_calls set_call_recording].freeze

  def self.actions
    ChatwootApp.enterprise? ? ACTIONS + ENTERPRISE_ACTIONS : ACTIONS
  end

  private

  def toybaco_inbox_provider_available
    type = Toybaco::ChannelAvailability.type_for(@inbox.channel)
    return if type.nil? || Toybaco::ChannelAvailability.enabled?(type)

    Rails.logger.warn("Toybaco API rejected: #{type} channel is not offered")
    render_could_not_create_error(Toybaco::ChannelAvailability.error)
  end
end
