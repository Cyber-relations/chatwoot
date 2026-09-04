# frozen_string_literal: true

# v4.17.1 で消えた SupportMailbox を、ReplyMailbox の会話作成経路のまま戻す。
# before_processing が落ちても perform_processing の ensure で経路ログを出す。
# 原本は inbound_email.source。Mail が Message-ID を書き換えても token を同じ行へ残す。
class SupportMailbox < ReplyMailbox
  def perform_processing
    super
  ensure
    log_toybaco_support_route
  end

  private

  def log_toybaco_support_route
    created = if conversation.respond_to?(:persisted?)
                conversation.persisted?
              else
                !conversation.nil?
              end
    raw = inbound_email.respond_to?(:source) ? inbound_email.source : nil
    Toybaco::InboundEmail.emit_cloudwatch_line(
      Toybaco::InboundEmail.log_mailbox_route(
        mail,
        mailbox: 'SupportMailbox',
        conversation: created,
        raw: raw
      )
    )
  rescue StandardError
    nil
  end
end
