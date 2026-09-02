# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Checkout
    # セルフサーブ対象プランと Stripe lookup_key の対応。
    module Catalog
      PLANS = %w[light standard pro].freeze
      CYCLES = %w[month year].freeze
      LOCALE = 'ja'
      CURRENCY = 'jpy'
      COUNTRY = 'JP'
      DEFAULT_SUCCESS_URL = 'https://toybaco.jp/welcome/'
      DEFAULT_CANCEL_BASE = 'https://toybaco.jp/signup/'
      OPTIONAL_LOOKUP_KEYS = {
        'month' => %w[setup-standard opt-store],
        'year' => %w[setup-standard]
      }.freeze
      LOOKUP_KEYS = {
        'light' => { 'month' => 'light', 'year' => 'light-annual' },
        'standard' => { 'month' => 'standard', 'year' => 'standard-annual' },
        'pro' => { 'month' => 'pro', 'year' => 'pro-annual' }
      }.freeze
      PRICE_ENV_KEYS = {
        'light' => 'TOYBACO_STRIPE_PRICE_LIGHT',
        'light-annual' => 'TOYBACO_STRIPE_PRICE_LIGHT_ANNUAL',
        'standard' => 'TOYBACO_STRIPE_PRICE_STANDARD',
        'standard-annual' => 'TOYBACO_STRIPE_PRICE_STANDARD_ANNUAL',
        'pro' => 'TOYBACO_STRIPE_PRICE_PRO',
        'pro-annual' => 'TOYBACO_STRIPE_PRICE_PRO_ANNUAL'
      }.freeze
      INDUSTRIES = [
        %w[beauty 美容室・サロン],
        %w[food 飲食店],
        %w[estate 不動産],
        %w[retailec 小売・EC],
        %w[clinic クリニック・歯科・治療院],
        %w[school スクール・塾],
        %w[auto 自動車(販売・整備)],
        %w[reform 住宅設備・リフォーム],
        %w[hotel 宿泊(旅館・ゲストハウス)],
        %w[bridalphoto 冠婚葬祭・写真館],
        %w[pet ペット(トリミング・動物病院)],
        %w[pro 士業・コンサル]
      ].freeze
      PRICE_ID = /\Aprice_[A-Za-z0-9]+\z/
      CUSTOMER_ID = /\Acus_[A-Za-z0-9]+\z/
      LIGHT_NO_SNS = 'SNS投稿機能はありません'
      PRODUCT_NAMES = {
        'light' => 'トイバコ ライト',
        'standard' => 'トイバコ スタンダード',
        'pro' => 'トイバコ プロ'
      }.freeze
      PRODUCT_DESCRIPTIONS = {
        'light' => "問い合わせ管理だけを小さく始めたいお店に。LINE・メール・Webチャット/3名まで。#{LIGHT_NO_SNS}",
        'standard' => 'Instagram・SNS投稿まで全部使いたいお店に。人数無制限',
        'pro' => 'AI応答(月500件)で夜間・繁忙時間まで自動化したいお店に'
      }.freeze
      # ご契約画面の客面名。LP https://toybaco.jp/pricing のセルフサーブ3プランに固定する。
      CUSTOMER_PLAN_NAMES = {
        'light' => 'ライト',
        'standard' => 'スタンダード',
        'pro' => 'プロ'
      }.freeze
      MONTHLY_AMOUNTS = {
        'light' => { price: 9_800, total: 10_780 },
        'standard' => { price: 29_800, total: 32_780 },
        'pro' => { price: 44_800, total: 49_280 }
      }.freeze
      # 旧 lookup_key は改名のみ。第4の消費者プランは作らない。
      PLAN_KEY_ALIASES = {
        'starter' => 'light'
      }.freeze

      module_function

      def billing_info(plan_key)
        key = PLAN_KEY_ALIASES[plan_key.to_s] || plan_key.to_s
        name = CUSTOMER_PLAN_NAMES[key]
        amounts = MONTHLY_AMOUNTS[key]
        return unless name && amounts

        { name: name, price: amounts[:price], total: amounts[:total] }
      end
    end
  end
end
