# frozen_string_literal: true

# ダッシュボードの API で、上流が 500 にする入力の誤り(NUL・enum の外の値・reports の壊れた期間・無い監査ログ)を 4xx で返す。
Rails.application.config.to_prepare do
  Toybaco::Security::ApiInputGuard.install!
end
