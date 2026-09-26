# frozen_string_literal: true

# 運営の通知先へ送る開通の状況(完了・確認が必要)。本文は Growth::OpeningOperations が組み立てる。
class Toybaco::OperationsMailer < ApplicationMailer
  def notice
    @body = params.fetch(:body)
    mail(to: params.fetch(:to), subject: params.fetch(:subject)) do |format|
      format.text { render 'toybaco/operations_mailer/notice', layout: false }
    end
  end

  private

  # 送信の失敗を握りつぶさず、ActiveJob の再試行に任せる。
  def handle_smtp_exceptions(error)
    raise error
  end
end
