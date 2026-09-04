# frozen_string_literal: true

# v4.17.1 で消えた SupportMailbox を、ReplyMailbox の会話作成経路のまま戻す。
# ログは process が落ちても ensure で出し、fixture token を同じ行へ残す。
class SupportMailbox < ReplyMailbox
  def process
    super
  ensure
    log_toybaco_support_route
  end

  private

  def log_toybaco_support_route
    created = if conversation.respond_to?(:persisted?)
                conversation.persisted?
              else
                conversation.present?
              end
    Rails.logger.info(
      Toybaco::InboundEmail.log_mailbox_route(
        mail,
        mailbox: 'SupportMailbox',
        conversation: created
      )
    )
  end
end
