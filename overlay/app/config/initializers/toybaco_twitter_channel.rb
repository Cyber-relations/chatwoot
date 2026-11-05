# frozen_string_literal: true

Rails.application.config.to_prepare do
  Inbox.include(Toybaco::Security::TwitterInboxGuard)
  Inbox.before_validation :toybaco_twitter_inbox_available, on: :create, prepend: true
  Inbox.before_create :toybaco_twitter_inbox_available, prepend: true

  guard = Toybaco::Security::TwitterChannelGuard
  Api::V1::WebhooksController.include(guard)
  # Both synchronous webhook actions stop before params, CRC or event parsing.
  Api::V1::WebhooksController.prepend_before_action :toybaco_twitter_available, only: %i[twitter_crc twitter_events]

  # Stop OAuth before token exchange, Redis lookup, or provider subscription.
  Twitter::CallbacksController.include(guard)
  Twitter::CallbacksController.prepend_before_action :toybaco_twitter_available, only: :show

  Api::V1::Accounts::Twitter::AuthorizationsController.before_action(only: :create) do
    unless Toybaco::ChannelAvailability.enabled?('twitter')
      render json: { success: false, error: Toybaco::ChannelAvailability.error }, status: :unprocessable_entity
    end
  end
end
