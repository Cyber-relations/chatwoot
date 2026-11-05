# frozen_string_literal: true

require 'uri'

module Toybaco::ChannelAvailability::ProviderJobBoundaries
  # target => [entry method, type resolver, unavailable handling]. Keep async
  # listeners here too: rescuing EventDispatcherJob would replay other listeners.
  TARGETS = {
    'Channels::Whatsapp::TemplatesSyncJob' => %i[perform whatsapp skip],
    'Channels::Whatsapp::TemplatesSyncSchedulerJob' => %i[perform whatsapp skip],
    'Channels::Whatsapp::HealthSyncJob' => %i[perform whatsapp skip],
    'Channels::Whatsapp::HealthSyncSchedulerJob' => %i[perform whatsapp skip],
    'Channels::Twilio::TemplatesSyncJob' => %i[perform channel skip],
    'Channels::Twilio::WebhookSetupJob' => %i[perform channel skip],
    'Voice::Provider::Twilio::RecordingAttachmentJob' => %i[perform recording skip],
    'Webhooks::WhatsappEventsJob' => %i[perform whatsapp skip],
    'Webhooks::SmsEventsJob' => %i[perform sms skip],
    'Webhooks::TwilioEventsJob' => %i[perform twilio_event skip],
    'Avatar::AvatarFromUrlJob' => %i[perform avatar skip],
    'SendReplyJob' => %i[perform reply fail_message],
    'Campaigns::TriggerOneoffCampaignJob' => %i[perform campaign complete_campaign],
    'CsatSurveyListener' => %i[conversation_status_changed csat skip]
  }.freeze

  def self.install
    TARGETS.each do |name, (entry, resolver, handler)|
      next if name.start_with?('Voice::') && !ChatwootApp.enterprise?

      Toybaco::ChannelAvailability::ProviderJobGuard.install(name.constantize, entry, method(resolver), method(handler))
    end
  end

  def self.whatsapp(*)
    'whatsapp'
  end

  def self.sms(*)
    'sms'
  end

  def self.channel(record)
    Toybaco::ChannelAvailability.type_for(record)
  end

  def self.recording(call_id, *)
    call = Call.find_by(id: call_id)
    ['voice', channel(call&.inbox&.channel)]
  end

  def self.twilio_event(params = {})
    payload = params.with_indifferent_access
    payload.values_at(:To, :From).any? { |number| number.to_s.start_with?('whatsapp:') } ? 'whatsapp' : 'sms'
  end

  def self.reply(message_id)
    channel(Message.find(message_id).conversation.inbox.channel)
  end

  def self.avatar(avatarable, url)
    return 'twitter' if avatarable.is_a?(Inbox) && channel(avatarable.channel) == 'twitter'

    'twitter' if %w[pbs.twimg.com abs.twimg.com].include?(URI.parse(url.to_s).host&.downcase)
  rescue URI::InvalidURIError
    nil
  end

  def self.campaign(record)
    channel(record.inbox.channel)
  end

  def self.csat(event)
    channel(event.data[:conversation].inbox.channel)
  end

  def self.skip(*); end

  # Only replies upstream would still deliver (Base::SendOnChannelService#perform):
  # public outgoing/template messages without a provider id, not voice calls, still
  # in the default sent status. Notes, incoming/activity and delivered ones keep theirs.
  def self.fail_message(message_id)
    message = Message.find_by(id: message_id)
    message&.with_lock do
      next unless undelivered_reply?(message)

      Messages::StatusUpdateService.new(message, 'failed', Toybaco::ChannelAvailability.error).perform
    end
  end

  def self.undelivered_reply?(message)
    (message.outgoing? || message.template?) && !message.private? && message.source_id.blank? &&
      message.content_type != 'voice_call' && message.sent?
  end

  def self.complete_campaign(record)
    # The pin has no cancelled/failed status. completed is terminal and excluded
    # from TriggerScheduledItemsJob's active scope; the callback sets completed_at.
    record.with_lock { record.completed! unless record.completed? }
  end
end
