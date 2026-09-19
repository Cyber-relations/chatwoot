# frozen_string_literal: true

class Toybaco::ConnectionHandoffMailer < ApplicationMailer
  def verification(recipient, code)
    mail(from: ENV.fetch('MAILER_SENDER_EMAIL'), to: recipient,
         subject: I18n.t('toybaco.connection_handoff.verification_subject', locale: :ja)) do |format|
      format.text { render plain: "接続設定の確認コード: #{code}\n\n10分以内に、コードを要求した画面へ入力してください。\n心当たりがない場合は、このメールを破棄してください。" }
    end
  end

  private

  def handle_smtp_exceptions(error)
    raise error
  end
end
