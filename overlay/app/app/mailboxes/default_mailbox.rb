# frozen_string_literal: true

# 未知宛先は会話を作らない。token 付きで DefaultMailbox と分かるように残す。
class DefaultMailbox < ApplicationMailbox
  def process
    Rails.logger.info(
      Toybaco::InboundEmail.mailbox_route_log(
        mailbox: 'DefaultMailbox',
        message_id: mail.message_id,
        conversation: false
      )
    )
  end
end
