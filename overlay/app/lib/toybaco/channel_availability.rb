# frozen_string_literal: true

module Toybaco::ChannelAvailability
  class Unavailable < StandardError; end

  def self.ensure_enabled!(types)
    return if Array(types).all? { |type| enabled?(type) }

    raise Unavailable, error
  end

  # Product switches, independent of account feature bits. Re-enabling a channel
  # requires a provider authentication review; all are off in Toybaco.
  def self.enabled?(type)
    case type.to_s
    when 'sms', 'voice' then ENV['TOYBACO_SMS_ENABLED'] == 'true'
    when 'whatsapp', 'whatsapp_call' then ENV['TOYBACO_WHATSAPP_ENABLED'] == 'true'
    when 'twitter', 'twitter_profile' then ENV['TOYBACO_TWITTER_ENABLED'] == 'true'
    else true
    end
  end

  def self.for_dashboard
    { sms: enabled?('sms'), whatsapp: enabled?('whatsapp'), twitter: enabled?('twitter') }
  end

  def self.error
    'この接続先は現在提供していません。'
  end

  def self.type_for(channel)
    case channel.class.name
    when 'Channel::Sms' then 'sms'
    when 'Channel::Whatsapp' then 'whatsapp'
    when 'Channel::TwitterProfile' then 'twitter'
    when 'Channel::TwilioSms' then channel.medium == 'whatsapp' ? 'whatsapp' : 'sms'
    end
  end

  module CreationGuard
    private

    def toybaco_channel_available
      return if Toybaco::ChannelAvailability.enabled?(Toybaco::ChannelAvailability.type_for(self))

      errors.add(:base, Toybaco::ChannelAvailability.error)
      throw :abort
    end
  end

  module WebhookGuard
    private

    def toybaco_channel_available
      type = controller_name == 'sms' ? 'sms' : 'whatsapp'
      return if Toybaco::ChannelAvailability.enabled?(type)

      Rails.logger.warn("Toybaco webhook rejected: #{type} channel is not offered")
      head :not_found
    end
  end

  module TwilioWebhookGuard
    private

    def toybaco_channel_available
      type = [params[:To], params[:From]].any? { |number| number.to_s.start_with?('whatsapp:') } ? 'whatsapp' : 'sms'
      return if Toybaco::ChannelAvailability.enabled?(type)

      Rails.logger.warn("Toybaco webhook rejected: #{type} channel is not offered")
      head :not_found
    end
  end
end
