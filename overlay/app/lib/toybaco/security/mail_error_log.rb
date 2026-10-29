# frozen_string_literal: true

# ActionMailer の log subscriber(actionmailer 7.2 log_subscriber.rb)は、配送の失敗を INFO の
# 「Failed delivery of mail … error_message=…」に出す。SMTP の応答は宛先のメールアドレスを含むので、JobErrorLog と同じく
# ログの間だけ例外の文を伏せる。配送の例外そのもの(再試行・raise_delivery_errors)は変えない。
module Toybaco::Security::MailErrorLog
  def deliver(event)
    Toybaco::Security::ExceptionLog.with_redacted_errors(event.payload) { super }
  end
end
