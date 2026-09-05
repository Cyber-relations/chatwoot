# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Checkout
    # 検証済み円建て Price の金額だけを使い、商品説明は LP 文言で載せる。
    # 既存 Price ID / USD Product は Session に渡さない。
    module LineItem
      module_function

      def subscription(input)
        price = input.fetch(:price)
        plan = input.fetch(:plan)
        {
          'line_items[0][quantity]' => '1',
          'line_items[0][price_data][currency]' => Catalog::CURRENCY,
          'line_items[0][price_data][unit_amount]' => price.fetch('unit_amount').to_s,
          'line_items[0][price_data][recurring][interval]' => input.fetch(:cycle),
          'line_items[0][price_data][tax_behavior]' => 'exclusive',
          'line_items[0][price_data][product_data][name]' => Catalog::PRODUCT_NAMES.fetch(plan),
          'line_items[0][price_data][product_data][description]' => Catalog::PRODUCT_DESCRIPTIONS.fetch(plan),
          'line_items[0][price_data][product_data][metadata][toybaco_plan]' => plan,
          'line_items[0][price_data][product_data][metadata][toybaco_plan_version]' => input.fetch(:version),
          'line_items[0][price_data][product_data][metadata][toybaco_reference_price_id]' => price.fetch('id')
        }
      end
    end
  end
end
