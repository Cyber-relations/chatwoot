# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    module PurchaseForm
      module_function

      def build(account:, user:, intent:, environment:)
        host = Checkout::Resolver.site_host(environment)
        return_url = "https://app.#{host}/toybaco/growth/purchase?account_id=#{account.id}"
        values = Checkout::SessionForm.locale_and_country.merge(
          'customer_email' => user.email, 'allow_promotion_codes' => 'false', 'payment_method_types[0]' => 'card',
          'line_items[0][price]' => intent.fetch('price_id'), 'line_items[0][quantity]' => '1',
          'client_reference_id' => account.id.to_s, 'expires_at' => intent.fetch('expires_at').to_s,
          'success_url' => "#{return_url}&growth_checkout=returned", 'cancel_url' => "#{return_url}&growth_checkout=cancelled"
        )
        metadata(account.id, intent).each do |key, value|
          values["metadata[#{key}]"] = value.to_s
          values["subscription_data[metadata][#{key}]"] = value.to_s
        end
        values
      end

      def metadata(account_id, intent)
        selection = intent.fetch('selection')
        { 'toybaco_existing_account_id' => account_id.to_s, 'toybaco_purchase_nonce' => intent.fetch('nonce'),
          'toybaco_billing_owner_id' => intent.fetch('owner_id').to_s, 'toybaco_plan' => selection.fetch('plan_id'),
          'toybaco_plan_version' => selection.fetch('plan_version'), 'toybaco_cycle' => selection.fetch('cycle'),
          'toybaco_reference_price_id' => intent.fetch('price_id') }
      end
    end
  end
end
