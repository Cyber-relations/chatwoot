# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Checkout
    # Checkout Session 作成用の form パラメータ。日本向け固定値をここに集約する。
    module SessionForm
      module_function

      def build(input)
        locale_and_country
          .merge(identity(input))
          .merge(custom_fields)
          .merge(optional_items(input[:optional_price_ids]))
      end

      def locale_and_country
        {
          'mode' => 'subscription',
          'locale' => Catalog::LOCALE,
          'currency' => Catalog::CURRENCY,
          'billing_address_collection' => 'required',
          'adaptive_pricing[enabled]' => 'false',
          'automatic_tax[enabled]' => 'true',
          'tax_id_collection[enabled]' => 'true',
          'allow_promotion_codes' => 'true',
          'payment_method_data[billing_details][address][country]' => Catalog::COUNTRY
        }
      end

      def identity(input)
        plan = input.fetch(:plan)
        cycle = input.fetch(:cycle)
        {
          'customer' => input.fetch(:customer_id),
          'customer_update[address]' => 'auto',
          'customer_update[name]' => 'auto',
          'metadata[toybaco_plan]' => plan,
          'metadata[toybaco_cycle]' => cycle,
          'subscription_data[metadata][toybaco_plan]' => plan,
          'subscription_data[metadata][toybaco_cycle]' => cycle,
          'success_url' => input.fetch(:success_url),
          'cancel_url' => input.fetch(:cancel_url)
        }.merge(LineItem.subscription(input))
      end

      def custom_fields
        fields = company_field.merge(industry_field)
        Catalog::INDUSTRIES.each_with_index do |(value, label), index|
          fields["custom_fields[1][dropdown][options][#{index}][label]"] = label
          fields["custom_fields[1][dropdown][options][#{index}][value]"] = value
        end
        fields
      end

      def company_field
        {
          'custom_fields[0][key]' => 'company',
          'custom_fields[0][label][type]' => 'custom',
          'custom_fields[0][label][custom]' => '会社名・店舗名',
          'custom_fields[0][type]' => 'text',
          'custom_fields[0][optional]' => 'false'
        }
      end

      def industry_field
        {
          'custom_fields[1][key]' => 'industry',
          'custom_fields[1][label][type]' => 'custom',
          'custom_fields[1][label][custom]' => '業種(初期設定パックを適用します)',
          'custom_fields[1][type]' => 'dropdown',
          'custom_fields[1][optional]' => 'false'
        }
      end

      def optional_items(optional_price_ids)
        items = {}
        Array(optional_price_ids).each_with_index do |price_id, index|
          next unless price_id.to_s.match?(Catalog::PRICE_ID)

          items["optional_items[#{index}][price]"] = price_id
          items["optional_items[#{index}][quantity]"] = '1'
        end
        items
      end
    end
  end
end
