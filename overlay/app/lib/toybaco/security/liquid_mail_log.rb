# frozen_string_literal: true

# 上流の ApplicationMailer#send_mail_with_liquid(v4.18.0 32-41 行)は、通知のメールの宛先と題を「Email sent to <宛先> with
# subject <題>」として Rails.logger.info に出す。題は利用者名・受信箱名を含む(AgentNotifications::ConversationNotificationsMailer
# など)。上流と同じメールを作り、ログには mailer と action の名前だけを出す(CASA 6.5.1)。上流の版を上げるときは、この写しを
# 上流の本体と照らし合わせる。
module Toybaco::Security::LiquidMailLog
  private

  def send_mail_with_liquid(*)
    Rails.logger.info "Email sent by #{self.class.name}##{action_name}"
    mail(*) do |format|
      format.html { render }
    end
  end
end
