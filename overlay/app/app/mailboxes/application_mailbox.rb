# frozen_string_literal: true

# Chatwoot v4.17.1 は SupportMailbox を ReplyMailbox に統合し、To が
# Mail::AddressContainer でないと EmailChannelFinder の前に DefaultMailbox へ落とす。
# SES の取り込みと fixture は原本の前の X-Original-To・Delivered-To に gem の destination(SES の通知の
# mail.destination の先頭。MIME の To・Cc 由来で、封筒の宛先(RCPT TO)ではない)を、再投入は先頭の SES の
# Received の for を載せる。EmailChannelFinder(To・Cc・これらの header と、先頭の SES の Received の for)が
# 公開受信アドレスに一致したら SupportMailbox へ戻す。
# 経路決定の時点で token 付きログを出し、FilterLogEvents が mailbox 名と結べるようにする。
# finder が落ちてもログは先に残す。原本は inbound_email.source を使う。
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

      mail = inbound_mail.respond_to?(:mail) ? inbound_mail.mail : inbound_mail
      raw = inbound_email_raw(inbound_mail)
      route = toybaco_resolve_route(mail)
      Toybaco::InboundEmail.emit_cloudwatch_line(
        Toybaco::InboundEmail.log_mailbox_route(
          mail,
          mailbox: toybaco_mailbox_name(route),
          conversation: false,
          raw: raw
        )
      )
      inbound_mail.instance_variable_set(:@toybaco_mailbox_route, route)
      route
    end

    def toybaco_resolve_route(mail)
      return :default unless Toybaco::InboundEmail.valid_mailbox_recipients?(mail)

      Toybaco::InboundEmail.mailbox_route(
        mail,
        channel_found: EmailChannelFinder.new(mail).perform.present?
      )
    rescue StandardError
      :default
    end

    def toybaco_mailbox_name(route)
      case route
      when :support then 'SupportMailbox'
      when :reply then 'ReplyMailbox'
      else 'DefaultMailbox'
      end
    end

    def inbound_email_raw(inbound_mail)
      inbound_mail.source if inbound_mail.respond_to?(:source)
    rescue StandardError
      nil
    end
  end
end
