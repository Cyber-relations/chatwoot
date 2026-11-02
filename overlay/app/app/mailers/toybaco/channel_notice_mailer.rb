# frozen_string_literal: true

# 受信チャネルの token の案内(店舗の管理者宛て)。LINE の token の無効・期限の近さ(Toybaco::LineTokenVerifyJob)と、
# Instagram の token の期限の近さ(Toybaco::InstagramTokenRefreshJob)。運営宛ての Toybaco::OperationsMailer とは分け、
# 宛先は params の to(店舗の管理者)だけにする。Cc・Bcc や運営の宛先は足さない。
# 宛先を job の引数やログに載せないよう、呼び出し側は deliver_now で送る。
class Toybaco::ChannelNoticeMailer < ApplicationMailer
  def notice
    @body = params.fetch(:body)
    mail(to: params.fetch(:to), subject: params.fetch(:subject)) do |format|
      format.text { render 'toybaco/channel_notice_mailer/notice', layout: false }
    end
  end

  private

  # 送信の失敗を握りつぶさず、呼び出し側(TOYBACO_CHANNEL_NOTICE_FAILED と次の回の再送。LINE は翌日、Instagram は 4 時間後)に任せる。
  def handle_smtp_exceptions(error)
    raise error
  end
end
