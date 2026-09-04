# frozen_string_literal: true

# v4.17.1 で消えた SupportMailbox を、ReplyMailbox の会話作成経路のまま戻す。
# ログは fixture token と同じ Message-ID を含め、READ-ONLY 診断が拾えるようにする。
class SupportMailbox < ReplyMailbox
  after_processing :log_toybaco_support_route

  private

  def log_toybaco_support_route
    Rails.logger.info(
      Toybaco::InboundEmail.mailbox_route_log(
        mailbox: 'SupportMailbox',
        message_id: mail.message_id,
        conversation: conversation.present?
      )
    )
  end
end
