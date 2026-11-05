# frozen_string_literal: true

module Toybaco::Security::InboxesMailGuard
  private

  def check_smtp_connection(channel_data, smtp)
    smtp.extend(Toybaco::Security::MailSocketGuard)
    super
  end

  def enable_openssl_mode(value)
    Toybaco::Security::SmtpVerifyMode.context(value)
  end
end
