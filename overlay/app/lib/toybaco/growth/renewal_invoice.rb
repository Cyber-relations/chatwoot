# frozen_string_literal: true

require_relative '../plan_catalog'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # An invoice can mix a renewal with manual charges or a previous balance.
    # Voiding the whole invoice is allowed only for one exact renewal line.
    class RenewalInvoice
      ZERO_FIELDS = %w[starting_balance amount_shipping pre_payment_credit_notes_amount post_payment_credit_notes_amount].freeze

      def initialize(invoice, contract, failure)
        @invoice = invoice
        @contract = contract
        @failure = failure
      end

      def valid?
        lines = @invoice['lines']
        return false unless one_line?(lines)

        line = lines['data'].first
        line.is_a?(Hash) && clean_balance? && line_identity?(line) && matching_period?(line) && matching_amount?(line)
      rescue PlanCatalog::Invalid, KeyError, TypeError
        false
      end

      private

      def one_line?(lines)
        lines.is_a?(Hash) && lines['has_more'] == false && lines['data'].is_a?(Array) && lines['data'].one?
      end

      def clean_balance?
        ZERO_FIELDS.all? { |field| @invoice[field].is_a?(Integer) && @invoice[field].zero? } &&
          empty_adjustment?(@invoice['discounts']) && empty_adjustment?(@invoice['total_discount_amounts'])
      end

      def empty_adjustment?(value)
        value.nil? || value == []
      end

      def line_identity?(line)
        parent = line['parent']
        return legacy_identity?(line) unless parent

        return false unless parent.is_a?(Hash) && parent['type'] == 'subscription_item_details'

        matching_details?(parent['subscription_item_details']) && line.dig('pricing', 'price_details', 'price') == @contract['stripe_price_id']
      end

      def matching_details?(details)
        details.is_a?(Hash) && details['subscription'] == @failure['subscription_id'] &&
          details['subscription_item'] == @contract['subscription_item_id'] && details['proration'] == false
      end

      def legacy_identity?(line)
        line['type'] == 'subscription' && line['subscription'] == @failure['subscription_id'] &&
          line['subscription_item'] == @contract['subscription_item_id'] && line['proration'] == false &&
          line.dig('price', 'id') == @contract['stripe_price_id']
      end

      def matching_period?(line)
        line.dig('period', 'start') == @failure['term_start'] && line.dig('period', 'end') == @failure['term_end']
      end

      def matching_amount?(line)
        terms = PlanCatalog.default.definition(@contract.fetch('plan_id'), @contract.fetch('plan_version'))
        amount = terms.fetch('cycles').fetch(@contract.fetch('cycle')).fetch('amount')
        amount.is_a?(Integer) && amount.positive? && line['amount'] == amount && @invoice['subtotal'] == amount &&
          line['quantity'] == 1 && line['currency'] == 'jpy' && empty_adjustment?(line['discount_amounts'])
      end
    end
  end
end
