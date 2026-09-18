# frozen_string_literal: true

require_relative '../../../lib/toybaco/connections/gmail_send'

class Toybaco::GmailResolveSendJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform(message_id, attempt = 0)
    message = Message.find_by(id: message_id)
    return unless message

    Toybaco::Connections::GmailSend.new(message).resolve
    saved = message.reload.content_attributes['toybaco_gmail_send']
    return unless saved.is_a?(Hash) && %w[sending uncertain].include?(saved['state']) && attempt < 3

    self.class.set(wait: (60 * (attempt + 1)).seconds).perform_later(message_id, attempt + 1)
  rescue Toybaco::Connections::GmailApi::Error, IOError, Timeout::Error, SocketError
    self.class.set(wait: 5.minutes).perform_later(message_id, attempt + 1) if attempt < 3
  end
end
