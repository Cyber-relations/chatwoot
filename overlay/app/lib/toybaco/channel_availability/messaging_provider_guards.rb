# frozen_string_literal: true

module Toybaco::ChannelAvailability::MessagingProviderGuards
  TWILIO_SERVICES = {
    'Twilio::TemplateSyncService' => %i[call client],
    'Twilio::WebhookSetupService' => %i[perform twilio_client],
    'Twilio::HealthService' => %i[perform],
    'Twilio::MediaDownloadService' => %i[perform download_with_auth download_without_auth retry_without_auth]
  }.freeze
  CSAT_METHODS = %i[create_template submit_for_approval delete_template fetch_template fetch_approval_status].freeze
  VOICE_SERVICES = {
    'Twilio::VoiceWebhookSetupService' => %i[perform sync_twiml_app! configure_number_webhooks! validate_token_credentials! create_twiml_app!],
    'Twilio::VoiceTeardownService' => %i[delete_twiml_app clear_number_webhooks]
  }.freeze

  def self.install
    guard = Toybaco::ChannelAvailability::ProviderGuard
    guard.install(Channel::TwilioSms, %i[client]) { Toybaco::ChannelAvailability.type_for(self) }
    guard.install(Channel::Sms, %i[send_message send_text_message send_to_bandwidth validate_provider_config]) { 'sms' }
    guard.install(Sms::IncomingMessageService, %i[download_media]) { 'sms' }
    guard.install(Channel::TwitterProfile, %i[twitter_client]) { 'twitter' }
    guard.install(Twitter::SendOnTwitterService, %i[twitter_client]) { 'twitter' }
    guard.install(TwitterConcern, %i[twitter_client]) { 'twitter' }
    install_twilio_services(guard)
    install_voice_services(guard) if ChatwootApp.enterprise?
  end

  def self.install_twilio_services(guard)
    TWILIO_SERVICES.each do |name, methods|
      guard.install(name.constantize, methods) { Toybaco::ChannelAvailability.type_for(channel) }
    end
    guard.install(Twilio::CsatTemplateApiClient, CSAT_METHODS) { Toybaco::ChannelAvailability.type_for(@twilio_channel) }
    guard.install(Api::V1::Accounts::Channels::TwilioChannelsController, %i[authenticate_twilio]) do
      params.dig(:twilio_channel, :medium) == 'whatsapp' ? 'whatsapp' : 'sms'
    end
  end

  def self.install_voice_services(guard)
    # Voice additionally requires the SMS/voice switch, even on a Twilio WhatsApp row.
    VOICE_SERVICES.each do |name, methods|
      guard.install(name.constantize, methods) { ['voice', Toybaco::ChannelAvailability.type_for(channel)] }
    end
    guard.install(Voice::Provider::Twilio::Adapter, %i[twilio_client]) do
      ['voice', Toybaco::ChannelAvailability.type_for(@channel)]
    end
    guard.install(Voice::Provider::Twilio::ConferenceService, %i[end_conference]) do
      ['voice', Toybaco::ChannelAvailability.type_for(call.inbox.channel)]
    end
    guard.install(Voice::Provider::Twilio::RecordingAttachmentService, %i[perform]) do
      ['voice', Toybaco::ChannelAvailability.type_for(call.inbox.channel)]
    end
  end
end
