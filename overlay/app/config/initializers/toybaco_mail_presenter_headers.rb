# frozen_string_literal: true

# 段 2a: 一斉配信・自動送信・配信不能の見分けに使うヘッダーを、受信メールの content_attributes['email']['headers'] に残す
# (Toybaco::Growth::AutomatedMail が読む)。
Rails.application.config.to_prepare do
  MailPresenter.prepend(Toybaco::MailPresenterHeaders)
end
