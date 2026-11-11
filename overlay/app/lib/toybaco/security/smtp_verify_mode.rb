# frozen_string_literal: true

module Toybaco::Security::SmtpVerifyMode
  # Older inboxes may store 'none'. Enforce peer verification when building
  # the transport without rewriting mailbox settings or credentials.
  def self.normalize(_value)
    'peer'
  end

  def self.context(_value)
    Net::SMTP.default_ssl_context.tap do |context|
      context.verify_mode = OpenSSL::SSL::VERIFY_PEER
      context.verify_hostname = true
    end
  end
end
