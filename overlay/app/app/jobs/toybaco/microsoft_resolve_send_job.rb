# frozen_string_literal: true

require_relative '../../../lib/toybaco/connections/microsoft_send'

class Toybaco::MicrosoftResolveSendJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform(message_id, attempt = 0)
    message = Message.find_by(id: message_id)
    return unless message

    Toybaco::Connections::MicrosoftSend.new(message).resolve
    saved = message.reload.content_attributes[Toybaco::Connections::MicrosoftSend::KEY]
    return unless needs_resolution?(saved, attempt)

    self.class.set(wait: (60 * (attempt + 1)).seconds).perform_later(message_id, attempt + 1)
  rescue Toybaco::Connections::MicrosoftApi::Error, IOError, Timeout::Error, SocketError
    self.class.set(wait: 5.minutes).perform_later(message_id, attempt + 1) if attempt < 3
  end

  private

  def needs_resolution?(saved, attempt)
    saved.is_a?(Hash) && !saved['sent_copy_at'] && %w[preparing sending uncertain accepted].include?(saved['state']) && attempt < 3
  end
end
