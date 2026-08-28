# frozen_string_literal: true

class DefaultToybacoAccountsToJapanese < ActiveRecord::Migration[7.1]
  ENGLISH_LOCALE = 0
  JAPANESE_LOCALE = 7

  def up
    change_column_default :accounts, :locale, from: ENGLISH_LOCALE, to: JAPANESE_LOCALE

    # Chatwoot既定値のまま英語になっている既存accountを日本語へ移す。
    # 他言語を明示選択したaccountは変更しない。
    execute <<~SQL.squish
      UPDATE accounts
      SET locale = #{JAPANESE_LOCALE}
      WHERE locale = #{ENGLISH_LOCALE}
    SQL

    # user.ui_settings.locale はaccountより優先される。旧既定値の "en" が残ると
    # accountを日本語化しても英語UIが継続するため、英語だけを日本語へ移す。
    # 空値や他言語は利用者の明示設定として保持する。
    execute <<~SQL.squish
      UPDATE users
      SET ui_settings = jsonb_set(ui_settings, '{locale}', '"ja"'::jsonb, true)
      WHERE ui_settings ->> 'locale' = 'en'
    SQL
  end

  def down
    # 既定値だけを戻す。既存値は「元から英語」と「移行で日本語」を区別できないため
    # 推測で書き戻さず、データを保持する。
    change_column_default :accounts, :locale, from: JAPANESE_LOCALE, to: ENGLISH_LOCALE
  end
end
