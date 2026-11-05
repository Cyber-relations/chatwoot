# frozen_string_literal: true

module Toybaco::ChannelAvailability::AccountSeederGuard
  # Upstream demo data needs SMS, WhatsApp and X inboxes and first deletes the
  # account's existing data. Refuse before that deletion while any of them is off.
  def perform!
    unavailable = %w[sms whatsapp twitter].reject { |type| Toybaco::ChannelAvailability.enabled?(type) }
    raise ArgumentError, "Account seeding needs unavailable channels: #{unavailable.join(', ')}" if unavailable.any?

    super
  end
end
