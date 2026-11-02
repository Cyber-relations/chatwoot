# frozen_string_literal: true

# PUT /auth/password の再設定 token を、並行の要求でも 1 回だけ、期限内だけ使えるようにし、期限内の token なら確認の期限切れの未確認の利用者もパスワードの設定と同時に
# 確認する(Toybaco::Security::PasswordResetExpiry)。パスワードの再設定の申し込み(POST)とメールの文面は upstream のまま。
Rails.application.config.to_prepare do
  controller = DeviseOverrides::PasswordsController
  expiry = Toybaco::Security::PasswordResetExpiry
  controller.prepend(expiry) unless controller < expiry
end
