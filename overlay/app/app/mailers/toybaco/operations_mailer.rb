# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/opening_operations'

# 運営の通知先へ送る開通の状況(完了・確認が必要)。本文は Growth::OpeningOperations が組み立てる。
# digest は運営日次ダイジェスト(Toybaco::Ops::Digest)で、本文の組み立ては Ops::Digest が行う。
class Toybaco::OperationsMailer < ApplicationMailer
  def notice
    @body = params.fetch(:body)
    mail(to: params.fetch(:to), subject: params.fetch(:subject)) do |format|
      format.text { render 'toybaco/operations_mailer/notice', layout: false }
    end
  end

  # 宛先は job の引数に載せず(ActiveJob の enqueue・perform のログに運営のメールアドレスを出さない)、
  # 配送時に OpeningOperations.recipient で決める。宛先が無ければ mail を呼ばず、何も送らない(NullMail)。
  # LOG_LEVEL=debug では ActionMailer が配送したメールの全文(To ヘッダを含む)をログに書くため、宛先が出る。
  # 本番は LOG_LEVEL を渡さず(infra/terraform/ecs.tf)、Chatwoot の production の既定 info で動かす。
  def digest
    to = Toybaco::Growth::OpeningOperations.recipient
    if to.blank?
      Rails.logger.warn('TOYBACO_OPS_DIGEST_SKIPPED reason=recipient')
      return
    end

    @body = params.fetch(:body)
    mail(to: to, subject: params.fetch(:subject)) do |format|
      format.text { render 'toybaco/operations_mailer/notice', layout: false }
    end
  end

  private

  # 送信の失敗を握りつぶさず、ActiveJob の再試行に任せる。
  def handle_smtp_exceptions(error)
    raise error
  end
end
