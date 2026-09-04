# frozen_string_literal: true

# Chatwoot v4.17.1 は SupportMailbox を ReplyMailbox に統合し、To が
# Mail::AddressContainer でないと EmailChannelFinder の前に DefaultMailbox へ落とす。
# SES fixture / envelope 宛先は X-Original-To・Delivered-To に載るので、
# 公開受信アドレスに一致したら SupportMailbox へ戻す。
# 経路決定の時点で token 付きログを出し、FilterLogEvents が mailbox 名と結べるようにする。
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
      return inbound_mail.instance_variable_get(:@toybaco_mailbox_route) if
        inbound_mail.instance_variable_defined?(:@toybaco_mailbox_route)

      mail = inbound_mail.mail
      route = if Toybaco::InboundEmail.valid_mailbox_recipients?(mail)
                Toybaco::InboundEmail.mailbox_route(
                  mail,
                  channel_found: EmailChannelFinder.new(mail).perform.present?
                )
              else
                :default
              end
      mailbox_name = case route
                     when :support then 'SupportMailbox'
                     when :reply then 'ReplyMailbox'
                     else 'DefaultMailbox'
                     end
      Rails.logger.info(
        Toybaco::InboundEmail.log_mailbox_route(mail, mailbox: mailbox_name, conversation: false)
      )
      inbound_mail.instance_variable_set(:@toybaco_mailbox_route, route)
      route
    end
  end
end
