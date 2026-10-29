# frozen_string_literal: true

# request body の外部キー(担当者・チーム・カテゴリー・関連記事・ヘルプセンター・受信箱・受信箱の担当者)と、
# 自動化ルール・マクロの action_params の id(宛先チーム・添付の blob)を店舗の中に閉じる。
Rails.application.config.to_prepare do
  Toybaco::Security::TenantForeignKeys.install!
  Toybaco::Security::TenantActionParams.install!
end
