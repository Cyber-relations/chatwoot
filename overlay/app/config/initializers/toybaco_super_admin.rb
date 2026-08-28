# frozen_string_literal: true

# トイバコ: 既定言語を日本語にし、SuperAdmin(管理コンソール)を常時日本語+トイバコ表記にする。
# 本体ファイルは書き換えず、initializer からのオーバーライドだけで済ませる。

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module SuperAdminAppConfigsLocalization
    private

    def success_notice
      group = I18n.t("toybaco.super_admin.config_groups.#{@config}", default: '詳細設定')
      message = "#{group}を更新しました。"
      return message unless restart_required_config_saved?

      "#{message} すべてのプロセスへ反映するには、Webとワーカーを再起動してください。"
    end
  end
end

# アカウント文脈の外(SuperAdmin・未ログインページ・メール等)の既定言語。
# ダッシュボードは従来どおり account/user の locale 設定が優先される。
Rails.application.config.after_initialize do
  I18n.default_locale = :ja if I18n.available_locales.include?(:ja)
end

Rails.application.config.to_prepare do
  # SuperAdmin 配下は常に日本語で描画する(administrate gem 同梱の ja 訳が効く)
  SuperAdmin::ApplicationController.class_eval do
    around_action :toybaco_force_ja_locale

    private

    # Ruby 3.1でもoverlayの構文検証ができるよう、匿名block forwardingは使わない。
    # rubocop:disable Naming/BlockForwarding, Style/ArgumentsForwarding
    def toybaco_force_ja_locale(&block)
      return yield unless I18n.available_locales.include?(:ja)

      I18n.with_locale(:ja, &block)
    end
    # rubocop:enable Naming/BlockForwarding, Style/ArgumentsForwarding
  end

  # ブラウザタブの「... - Chatwoot」を「... - トイバコ」へ
  # (administrate の application_title は Rails モジュール名 = Chatwoot を返す)
  Administrate::ApplicationHelper.module_eval do
    def application_title
      'トイバコ'
    end
  end

  unless SuperAdmin::AppConfigsController < Toybaco::SuperAdminAppConfigsLocalization
    SuperAdmin::AppConfigsController.prepend(Toybaco::SuperAdminAppConfigsLocalization)
  end

  # upstream helperのプラン説明は固定英語なので、表示ロジックだけ日本語へ置換する。
  SuperAdmin::FeaturesHelper.singleton_class.class_eval do
    define_method(:plan_details) do
      if ChatwootHub.pricing_plan == 'premium'
        "有償プラン（担当者 #{ChatwootHub.pricing_plan_quantity} 名）を利用中です。"
      else
        'コミュニティ版を利用中です。'
      end
    end
  end
end
