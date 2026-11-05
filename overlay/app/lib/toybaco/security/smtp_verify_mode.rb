# frozen_string_literal: true

module Toybaco::Security::SmtpVerifyMode
  MODES = {
    'none' => OpenSSL::SSL::VERIFY_NONE,
    'peer' => OpenSSL::SSL::VERIFY_PEER,
    'client_once' => OpenSSL::SSL::VERIFY_CLIENT_ONCE,
    'fail_if_no_peer_cert' => OpenSSL::SSL::VERIFY_FAIL_IF_NO_PEER_CERT
  }.freeze

  def self.normalize(value)
    name = value.to_s.downcase
    MODES.key?(name) ? name : 'none'
  end

  def self.context(value)
    Net::SMTP.default_ssl_context.tap do |context|
      context.verify_mode = MODES.fetch(normalize(value))
    end
  end
end
