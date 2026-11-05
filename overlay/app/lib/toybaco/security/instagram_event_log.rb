# frozen_string_literal: true

module Toybaco::Security::InstagramEventLog
  private

  def process_messages(entry)
    batch = messages(entry)
    Rails.logger.info("Instagram Events Job messages_count=#{batch.size}")
    batch.each do |messaging|
      channel = find_channel(instagram_id(messaging))
      next if channel.blank?

      event = event_name(messaging)
      send(event, messaging, channel) if event
    end
  end
end
