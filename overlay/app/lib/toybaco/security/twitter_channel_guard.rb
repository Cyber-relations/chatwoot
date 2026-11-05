# frozen_string_literal: true

module Toybaco::Security::TwitterChannelGuard
  private

  def toybaco_twitter_available
    return if Toybaco::ChannelAvailability.enabled?('twitter')

    Rails.logger.warn('Toybaco webhook rejected: twitter channel is not offered')
    head :not_found
  end
end
