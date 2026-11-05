# frozen_string_literal: true

module Toybaco::Security::MailDeliveryDestination
  private

  def smtp_timeout_settings
    super.merge(toybaco_public_destination: true)
  end
end
