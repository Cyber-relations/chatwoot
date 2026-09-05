# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Checkout
    # 新規販売で検証済みの Price を使い、Portal と契約同期に同じ価格を渡す。
    module LineItem
      module_function

      def subscription(input)
        {
          'line_items[0][quantity]' => '1',
          'line_items[0][price]' => input.fetch(:price).fetch('id')
        }
      end
    end
  end
end
