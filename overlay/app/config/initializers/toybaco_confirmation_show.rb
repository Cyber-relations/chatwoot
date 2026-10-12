# frozen_string_literal: true

# GET /auth/confirmation を置き換える(無認証 500 の解消、GET では確認しない)。HTML は SPA の確認画面へ、HTML 以外は 406。POST は upstream のまま。
Rails.application.config.to_prepare do
  controller = DeviseOverrides::ConfirmationsController
  redirect = Toybaco::Security::ConfirmationShowRedirect
  controller.prepend(redirect) unless controller < redirect
end
