# frozen_string_literal: true

require_relative '../../../lib/toybaco/connections/gmail'

class Toybaco::GmailRevokeJob < ApplicationJob
  queue_as :scheduled_jobs
  retry_on IOError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError, Toybaco::Connections::GmailApi::Error, wait: :polynomially_longer,
                                                                                                                attempts: 5

  def perform(ciphertext, purpose)
    credentials = Toybaco::Connections::Gmail.encryptor.decrypt_and_verify(ciphertext, purpose: purpose)
    return unless credentials.is_a?(Hash) && credentials['refresh_token'].present?

    Toybaco::Connections::Gmail.api.revoke(refresh_token: credentials.fetch('refresh_token'))
  rescue Toybaco::Connections::GmailApi::Error => e
    raise unless e.status == 400 && e.reason == 'invalid_token'
  end
end
