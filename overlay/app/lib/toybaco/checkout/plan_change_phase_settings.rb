# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Checkout
    module PlanChangePhaseSettings
      PHASE_FIELDS = %w[start_date end_date proration_behavior billing_cycle_anchor collection_method currency
                        default_payment_method default_tax_rates description invoice_settings metadata trial_end
                        application_fee_percent automatic_tax billing_thresholds discounts on_behalf_of transfer_data
                        add_invoice_items].freeze
      ITEM_FIELDS = %w[price quantity tax_rates metadata billing_thresholds discounts].freeze

      private

      def writable_phase(phase)
        reject_unknown!(phase, PHASE_FIELDS + ['items'])
        result = phase.slice(*PHASE_FIELDS).compact
        # Stripe returns [], but this optional invoice-item list cannot be unset with ''.
        result.delete('add_invoice_items') if result['add_invoice_items'] == []
        normalize_ids!(result, 'default_tax_rates')
        result['default_payment_method'] = object_id_value(result['default_payment_method']) if result.key?('default_payment_method')
        result['items'] = phase.fetch('items').map { |item| writable_item(item) }
        result
      end

      def writable_item(item)
        reject_unknown!(item, ITEM_FIELDS + ['plan'])
        result = item.slice(*ITEM_FIELDS).compact
        result['price'] = object_id_value(result['price'])
        normalize_ids!(result, 'tax_rates')
        result
      end

      def reject_unknown!(value, allowed)
        reject!('review') unless value.all? { |key, child| allowed.include?(key) || !present_value?(child) }
      end

      def normalize_ids!(value, key)
        value[key] = Array(value[key]).map { |child| object_id_value(child) }
      end

      def object_id_value(value)
        value.is_a?(Hash) ? value.fetch('id') : value
      end

      def contains_settings?(actual, expected)
        case expected
        when Hash
          actual.is_a?(Hash) && expected.all? { |key, value| contains_settings?(actual[key], value) }
        when Array
          matching_array?(actual, expected)
        else
          actual == expected
        end
      end

      def matching_array?(actual, expected)
        actual.is_a?(Array) && actual.length == expected.length && expected.each_with_index.all? do |value, index|
          contains_settings?(actual[index], value)
        end
      end
    end
  end
end
