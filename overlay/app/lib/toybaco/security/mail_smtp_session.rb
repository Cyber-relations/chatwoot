# frozen_string_literal: true

module Toybaco::Security::MailSmtpSession
  private

  def build_smtp_session
    return super unless settings[:toybaco_public_destination]

    settings[:openssl_verify_mode] = Toybaco::Security::SmtpVerifyMode.normalize(settings[:openssl_verify_mode])
    super.extend(Toybaco::Security::MailSocketGuard)
  end
end
