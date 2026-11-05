# frozen_string_literal: true

module Toybaco::Security::TwitterInboxGuard
  private

  def toybaco_twitter_inbox_available
    return unless channel_type == 'Channel::TwitterProfile'
    return if Toybaco::ChannelAvailability.enabled?('twitter')

    errors.add(:base, Toybaco::ChannelAvailability.error)
    throw :abort
  end
end
