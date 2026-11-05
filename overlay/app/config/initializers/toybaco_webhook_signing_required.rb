# frozen_string_literal: true

# SMS and WhatsApp are disabled by toybaco_channel_availability. Retain Cloud
# signature verification if the product switch is deliberately enabled later.
require_relative '../../lib/toybaco/security/facebook_signature_required'
Facebook::Messenger::Server.prepend(Toybaco::Security::FacebookSignatureRequired)

Rails.application.config.to_prepare do
  Webhooks::WhatsappController.prepend(Toybaco::Security::WhatsappSignatureRequired)
end
