# frozen_string_literal: true

# 未知宛先は会話を作らない。token 付きで DefaultMailbox と分かるように残す。
class DefaultMailbox < ApplicationMailbox
  def process
    raw = inbound_email.respond_to?(:source) ? inbound_email.source : nil
    Toybaco::InboundEmail.emit_cloudwatch_line(
      Toybaco::InboundEmail.log_mailbox_route(
        mail,
        mailbox: 'DefaultMailbox',
        conversation: false,
        raw: raw
      )
    )
  end
end
