# frozen_string_literal: true

module ToybacoChannelAvailabilityInitializer
  # Also cover model/service creation (including Platform API callers), before
  # provider validation or after_create hooks can contact a provider.
  def self.install_creation_guards(availability)
    [Channel::Sms, Channel::Whatsapp, Channel::TwilioSms, Channel::TwitterProfile].each do |channel|
      channel.include(availability::CreationGuard)
      channel.before_validation :toybaco_channel_available, on: :create, prepend: true
      channel.before_create :toybaco_channel_available, prepend: true
    end
    Seeders::InboxSeeder.prepend(availability::SeederGuard)
    Seeders::AccountSeeder.prepend(availability::AccountSeederGuard)
  end

  # Guard validation before Enterprise provisions TwiML, and save when callers
  # skip validation. Creation-only guards do not protect existing channels.
  def self.install_voice_guards(availability)
    Channel::TwilioSms.include(availability::TwilioVoiceActivationGuard)
    Channel::Whatsapp.prepend(availability::WhatsappVoiceActivationGuard)
    [Channel::TwilioSms, Channel::Whatsapp].each do |channel|
      channel.before_validation :toybaco_voice_activation_available, prepend: true
      channel.before_save :toybaco_voice_activation_available, prepend: true
    end

    return unless ChatwootApp.enterprise?

    Twilio::VoiceController.include(availability::TwilioVoiceWebhookGuard)
    Twilio::VoiceController.prepend_before_action :toybaco_voice_available
    install_call_api_guards(availability)
  end

  # Existing channels of a disabled type never reach their provider from any path
  # (see the provider guards); the CSAT template API also answers with the 422.
  def self.install_provider_stops(availability)
    availability::WhatsappProviderGuards.install
    availability::MessagingProviderGuards.install
    install_provider_boundaries(availability)
    Api::V1::Accounts::InboxCsatTemplatesController.include(availability::InboxProviderGuard)
    Api::V1::Accounts::InboxCsatTemplatesController.before_action :toybaco_inbox_provider_available, only: %i[show create]
  end

  # The JSON APIs answer with the 422. Registered on ApplicationController: a
  # rescue_from on Api::BaseController would copy the handler list here and hide
  # what later initializers add to ApplicationController (the inbox 409).
  def self.install_provider_boundaries(availability)
    availability::ProviderJobBoundaries.install
    ApplicationController.rescue_from availability::Unavailable do |error|
      raise error unless is_a?(Api::BaseController)

      render json: { error: Toybaco::ChannelAvailability.error }, status: :unprocessable_entity
    end
  end

  # Existing calls and voice inboxes stay unreachable: close the dashboard call
  # APIs before authentication, lookup, voice credentials or provider calls.
  def self.install_call_api_guards(availability)
    Api::V1::Accounts::WhatsappCallsController.include(availability::WhatsappCallsGuard)
    Api::V1::Accounts::WhatsappCallsController.prepend_before_action :toybaco_whatsapp_calls_available
    [Api::V1::Accounts::ConferenceController, Api::V1::Accounts::Contacts::CallsController].each do |controller|
      controller.include(availability::TwilioVoiceApiGuard)
      controller.prepend_before_action :toybaco_voice_api_available
    end
  end
end

Rails.application.config.to_prepare do
  availability = Toybaco::ChannelAvailability

  ToybacoChannelAvailabilityInitializer.install_creation_guards(availability)
  ToybacoChannelAvailabilityInitializer.install_provider_stops(availability)

  Api::V1::Accounts::InboxesController.before_action(only: :create) do
    render_could_not_create_error(availability.error) unless availability.enabled?(params.dig(:channel, :type))
  end

  # Existing inboxes of a disabled type must not update, re-register or query
  # their provider either. Deletion stays available for cleanup.
  Api::V1::Accounts::InboxesController.include(availability::InboxProviderGuard)
  Api::V1::Accounts::InboxesController.before_action :toybaco_inbox_provider_available,
                                                     only: availability::InboxProviderGuard.actions

  Api::V1::Accounts::Channels::TwilioChannelsController.before_action(only: :create) do
    type = params.dig(:twilio_channel, :medium) == 'whatsapp' ? 'whatsapp' : 'sms'
    render_could_not_create_error(availability.error) unless availability.enabled?(type)
  end

  Api::V1::Accounts::Whatsapp::AuthorizationsController.before_action(only: :create) do
    next if availability.enabled?('whatsapp')

    render json: { success: false, error: availability.error }, status: :unprocessable_entity
  end

  # All four actions, including webhook_status and setup_webhook for an existing
  # manual-setup inbox, stop before any Meta call while WhatsApp is off.
  Api::V1::Accounts::Whatsapp::ManualSetupController.before_action do
    next if availability.enabled?('whatsapp')

    render json: { message: availability.error }, status: :unprocessable_entity
  end

  [Webhooks::SmsController, Webhooks::WhatsappController].each do |controller|
    controller.include(availability::WebhookGuard)
    controller.prepend_before_action :toybaco_channel_available
  end

  [Twilio::CallbackController, Twilio::DeliveryStatusController].each do |controller|
    controller.include(availability::TwilioWebhookGuard)
    controller.prepend_before_action :toybaco_channel_available
  end

  ToybacoChannelAvailabilityInitializer.install_voice_guards(availability)
end
