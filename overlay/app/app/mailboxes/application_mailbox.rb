# frozen_string_literal: true

# Chatwoot v4.17.1 は SupportMailbox を ReplyMailbox に統合し、To が
# Mail::AddressContainer でないと EmailChannelFinder の前に DefaultMailbox へ落とす。
# SES fixture / envelope 宛先は X-Original-To・Delivered-To に載るので、
# 公開受信アドレスに一致したら SupportMailbox へ戻す。
class ApplicationMailbox < ActionMailbox::Base
  include MailboxHelper

  routing(
    lambda { |inbound_mail|
      ApplicationMailbox.toybaco_mailbox_for(inbound_mail) == :reply
    } => :reply
  )
  routing(
    lambda { |inbound_mail|
      ApplicationMailbox.toybaco_mailbox_for(inbound_mail) == :support
    } => :support
  )
  routing(all: :default)

  class << self
    def toybaco_mailbox_for(inbound_mail)
      mail = inbound_mail.mail
      return :default unless Toybaco::InboundEmail.valid_mailbox_recipients?(mail)

      Toybaco::InboundEmail.mailbox_route(
        mail,
        channel_found: EmailChannelFinder.new(mail).perform.present?
      )
    end
  end
end
