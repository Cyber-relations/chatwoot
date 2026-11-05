# frozen_string_literal: true

module Toybaco::Security::TelegramEventLog
  private

  def log_inactive_channel(channel, _params)
    message = if channel&.id
                "Account #{channel.account.id} is not active for channel #{channel.id}"
              else
                'Channel not found'
              end
    Rails.logger.warn("Telegram event discarded: #{message}")
  end
end
