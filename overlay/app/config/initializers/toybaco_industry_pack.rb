# frozen_string_literal: true

# 受信箱の新規作成時、アカウントに保存された業種(internal_attributes の
# toybaco_industry)の業界パックから不在メッセージを自動で入れる(未設定の場合のみ)。
# 営業時間そのものはお客様ごとに違うため、設定 > 受信トレイでの手動設定のまま。
require Rails.root.join('lib', 'toybaco', 'industry_pack')

Rails.application.config.to_prepare do
  Inbox.class_eval do
    unless method_defined?(:toybaco_apply_industry_out_of_office)
      after_create_commit :toybaco_apply_industry_out_of_office

      def toybaco_apply_industry_out_of_office
        Toybaco::IndustryPack.apply_out_of_office(self)
      end
    end
  end
end
