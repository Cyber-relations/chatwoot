# frozen_string_literal: true

require 'net/imap'
require 'net/smtp'
require 'mail'
require_relative '../../lib/toybaco/security/mail_destination'
require_relative '../../lib/toybaco/security/mail_socket_guard'
require_relative '../../lib/toybaco/security/smtp_verify_mode'
require_relative '../../lib/toybaco/security/mail_smtp_session'

# Every IMAP consumer (save-time check, periodic fetch, OAuth, trial verification)
# uses Net::IMAP. SMTP is scoped to channel settings; installation mail is separate.
Net::IMAP.prepend(Toybaco::Security::MailSocketGuard)
Mail::SMTP.prepend(Toybaco::Security::MailSmtpSession)

Rails.application.config.to_prepare do
  Channel::Email.prepend(Toybaco::Security::MailChannelDestination)
  Api::V1::InboxesHelper.prepend(Toybaco::Security::InboxesMailGuard)
  ConversationReplyMailerHelper.prepend(Toybaco::Security::MailDeliveryDestination)
end
