# frozen_string_literal: true

require_relative 'pack_catalog'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    module PackForm
      module_function

      def build(account_id, saved, environment:)
        host = Checkout::Resolver.site_host(environment)
        return_url = "https://app.#{host}/toybaco/growth/packs?account_id=#{account_id}&request_key=#{saved.fetch('request_key')}"
        values = Checkout::SessionForm.locale_and_country.merge(
          'mode' => 'payment', 'customer' => saved.fetch('customer_id'), 'customer_update[address]' => 'auto',
          'customer_update[name]' => 'auto', 'allow_promotion_codes' => 'false', 'payment_method_types[0]' => 'card',
          'payment_intent_data[capture_method]' => 'automatic',
          'line_items[0][price]' => saved.fetch('price_id'), 'line_items[0][quantity]' => '1',
          'client_reference_id' => account_id.to_s, 'expires_at' => saved.fetch('expires_at').to_s,
          'success_url' => "#{return_url}&pack_checkout=returned", 'cancel_url' => "#{return_url}&pack_checkout=cancelled"
        )
        metadata(account_id, saved).each do |key, value|
          values["metadata[#{key}]"] = value
          values["payment_intent_data[metadata][#{key}]"] = value
        end
        values
      end

      def metadata(account_id, saved)
        { 'toybaco_item' => 'ai_pack', 'toybaco_plan_version' => saved.fetch('version'),
          'toybaco_generations' => saved.fetch('units').to_s, 'toybaco_expiry_days' => saved.fetch('days').to_s,
          'toybaco_pack_account_id' => account_id.to_s, 'toybaco_pack_nonce' => saved.fetch('nonce'),
          'toybaco_billing_owner_id' => saved.fetch('owner_id').to_s, 'toybaco_reference_price_id' => saved.fetch('price_id') }
      end
    end
  end
end
