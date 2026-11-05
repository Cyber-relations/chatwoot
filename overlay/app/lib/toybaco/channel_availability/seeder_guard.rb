# frozen_string_literal: true

module Toybaco::ChannelAvailability::SeederGuard
  # The upstream WhatsApp seeder uses insert, which skips the model creation
  # guards. Skip every unavailable channel before it is written.
  { seed_twitter_inbox: 'twitter', seed_whatsapp_inbox: 'whatsapp', seed_sms_inbox: 'sms' }.each do |method_name, type|
    define_method(method_name) do
      return super() if Toybaco::ChannelAvailability.enabled?(type)

      Rails.logger.info("Toybaco seeder skipped: #{type} channel is not offered")
    end
  end
end
