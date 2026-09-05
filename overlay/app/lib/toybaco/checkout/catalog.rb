# frozen_string_literal: true

require_relative '../plan_catalog'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Checkout
    # セルフサーブ対象プランと Stripe lookup_key の対応。
    module Catalog
      DATA = Toybaco::PlanCatalog.default
      SALES = DATA.sales.freeze
      PLANS = SALES.map { |plan| plan.fetch('plan_id') }.freeze
      CYCLES = SALES.flat_map { |plan| plan.fetch('cycles').keys }.uniq.freeze
      LOCALE = DATA.data.fetch('locale')
      CURRENCY = DATA.data.fetch('currency')
      COUNTRY = DATA.data.fetch('country')
      DEFAULT_SUCCESS_URL = 'https://toybaco.jp/welcome/'
      DEFAULT_CANCEL_BASE = 'https://toybaco.jp/signup/'
      OPTIONAL_LOOKUP_KEYS = DATA.data.fetch('optional_lookup_keys')
      LOOKUP_KEYS = SALES.to_h do |plan|
        [plan.fetch('plan_id'), plan.fetch('cycles').transform_values { |price| price.dig('stripe', 'live', 'lookup_key') }]
      end.freeze
      PRICE_ENV_KEYS = SALES.flat_map do |plan|
        plan.fetch('cycles').values.map { |price| [price.dig('stripe', 'live', 'lookup_key'), price.dig('stripe', 'live', 'price_env')] }
      end.to_h.freeze
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
      PRODUCT_NAMES = SALES.to_h { |plan| [plan.fetch('plan_id'), plan.fetch('product_name')] }.freeze
      PRODUCT_DESCRIPTIONS = SALES.to_h { |plan| [plan.fetch('plan_id'), plan.fetch('description')] }.freeze
      CUSTOMER_PLAN_NAMES = SALES.to_h { |plan| [plan.fetch('plan_id'), plan.fetch('name')] }.freeze
      # Listing prices are never used as the actual amount billed to an existing subscriber.
      MONTHLY_AMOUNTS = SALES.to_h do |plan|
        amount = plan.dig('cycles', 'month', 'amount')
        [plan.fetch('plan_id'), { price: amount, total: (amount * (1 + DATA.data.fetch('display_tax_rate'))).round }]
      end.freeze
      PLAN_KEY_ALIASES = DATA.data.fetch('display_aliases')

      module_function

      def sale(plan, cycle, version: nil)
        DATA.sale(plan, cycle, version: version)
      end

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
