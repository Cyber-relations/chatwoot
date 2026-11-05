# frozen_string_literal: true

require_relative '../../lib/toybaco/security/facebook_verify_token'
Facebook::Messenger::Server.prepend(Toybaco::Security::FacebookVerifyToken::Handshake)

Rails.application.config.to_prepare do
  [Api::V1::Integrations::WebhooksController, Webhooks::InstagramController,
   Webhooks::TiktokController, Webhooks::ShopifyController, Webhooks::WhatsappController].each do |controller|
    controller.prepend(Toybaco::Security::WebhookBodyParams)
  end
  Webhooks::LineController.prepend(Toybaco::Security::LineWebhookBody)
  Webhooks::WhatsappController.prepend(Toybaco::Security::WhatsappWebhookBody)
  Webhooks::WhatsappEventsJob.prepend(Toybaco::Security::WhatsappEventRoute)
  Api::V1::Integrations::WebhooksController.prepend(Toybaco::Security::SlackSignatureRequired)
  Webhooks::TiktokController.prepend(Toybaco::Security::TiktokSignature)
  Webhooks::WhatsappController.prepend(Toybaco::Security::WhatsappVerifyToken)
  Webhooks::InstagramController.prepend(Toybaco::Security::InstagramVerifyToken)
  ChatwootFbProvider.prepend(Toybaco::Security::FacebookVerifyToken)
  Webhooks::TelegramController.prepend(Toybaco::Security::TelegramTokenRequired)
  Webhooks::TelegramEventsJob.prepend(Toybaco::Security::TelegramEventToken)
  Webhooks::TelegramEventsJob.prepend(Toybaco::Security::TelegramEventLog)
  Webhooks::LineEventsJob.prepend(Toybaco::Security::LineSignature)
  Webhooks::InstagramEventsJob.prepend(Toybaco::Security::InstagramEventLog)
  Shopify::CallbacksController.prepend(Toybaco::Security::ShopifyCallbackDomain)
  Webhooks::ShopifyController.prepend(Toybaco::Security::ShopifyCleanup)

  if ChatwootApp.enterprise?
    Enterprise::Webhooks::FirecrawlController.prepend(Toybaco::Security::FirecrawlAuthentication)
    Enterprise::Webhooks::StripeController.prepend(Toybaco::Security::StripeSigningRequired)
  end
end
