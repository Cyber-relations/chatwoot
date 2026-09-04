# frozen_string_literal: true

# 未知宛先は会話を作らない。token 付きで DefaultMailbox と分かるように残す。
class DefaultMailbox < ApplicationMailbox
  def process
    Rails.logger.info(
      Toybaco::InboundEmail.log_mailbox_route(
        mail,
        mailbox: 'DefaultMailbox',
        conversation: false
      )
    )
  end
end
