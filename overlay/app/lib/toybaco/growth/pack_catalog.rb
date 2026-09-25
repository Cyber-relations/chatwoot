# frozen_string_literal: true

require_relative '../checkout'
require_relative 'purchase_intent'
require_relative 'payment_signature'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    module PackCatalog
      VERSION = GrowthTerms::VERSION

      module_function

      def terms
        PlanCatalog.default.data.fetch('release_candidates').fetch(VERSION).fetch('ai_pack')
      end

      def available?
        terms['sellable'] == true && PaymentSignature.configured?
      end

      def resolve(client:, environment:)
        raise PurchaseIntent::Unavailable, '追加パックは現在準備中です。' unless available?

        mode = environment.fetch('TOYBACO_STRIPE_MODE', 'live')
        raise Checkout::Unavailable, 'invalid Stripe mode' unless %w[test live].include?(mode)

        reference = terms.fetch('stripe').fetch(mode)
        override = environment[reference.fetch('price_env')].to_s
        price = if override.match?(Checkout::Catalog::PRICE_ID)
                  client.retrieve_price(override)
                else
                  client.find_price_by_lookup_key(reference.fetch('lookup_key'))
                end
        verify!(price, mode)
        price
      end

      def verify!(price, mode)
        raise Checkout::Unavailable, '追加パックの商品を確認できません。' unless price.is_a?(Hash)

        values = { 'active' => true, 'type' => 'one_time', 'currency' => 'jpy', 'unit_amount' => terms.fetch('amount'),
                   'livemode' => mode == 'live', 'tax_behavior' => 'exclusive', 'billing_scheme' => 'per_unit',
                   'recurring' => nil, 'transform_quantity' => nil }
        valid = values.all? { |key, value| price[key] == value } && price['id'].to_s.match?(Checkout::Catalog::PRICE_ID)
        raise Checkout::Unavailable, '追加パックの価格・税区分が一致しません。' unless valid && matching_product?(price)
      end

      def matching_product?(price)
        product = price['product']
        product.is_a?(Hash) && product['active'] == true && product['name'] == terms.fetch('product_name') &&
          metadata.all? { |key, value| price.dig('metadata', key) == value }
      end

      def metadata
        { 'toybaco_item' => 'ai_pack', 'toybaco_plan_version' => VERSION,
          'toybaco_generations' => terms.fetch('generations').to_s, 'toybaco_expiry_days' => terms.fetch('expires_after_days').to_s }
      end
    end
  end
end
