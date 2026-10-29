# frozen_string_literal: true

# One confirmation link, one confirmation, also for simultaneous requests (Toybaco::Security::SingleUseConfirmation).
Rails.application.config.to_prepare do
  controller = DeviseOverrides::ConfirmationsController
  confirmation = Toybaco::Security::SingleUseConfirmation
  controller.prepend(confirmation) unless controller < confirmation
end
