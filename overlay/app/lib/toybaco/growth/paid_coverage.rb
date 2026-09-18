# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # Only a freshly retrieved Stripe subscription with its expanded, paid
    # invoice can establish coverage. Browser success URLs are never evidence.
    class PaidCoverage
      def initialize(subscription, contract)
        @subscription = subscription
        @contract = contract
      end

      def verified
        return unless @subscription['status'] == 'active' && @subscription['pause_collection'].nil?

        item = base_item
        return unless item && paid_invoice? && paid_line?(item)

        build(item)
      end

      private

      def base_item
        items = @subscription['items']
        return unless complete_list?(items)

        selected = items['data'].select { |item| item['id'] == @contract['subscription_item_id'] }
        return unless selected.size == 1 && selected.first['quantity'] == 1

        selected.first if selected.first.dig('price', 'id') == @contract['stripe_price_id']
      end

      def invoice
        @subscription['latest_invoice']
      end

      def paid_invoice?
        paid_status? &&
          %w[subscription_create subscription_cycle subscription_update].include?(invoice['billing_reason']) &&
          (invoice.dig('parent', 'subscription_details', 'subscription') || invoice['subscription']) == @subscription['id'] &&
          timestamp?(invoice.dig('status_transitions', 'paid_at'))
      end

      def paid_status?
        invoice.is_a?(Hash) && invoice['id'].to_s.match?(/\Ain_[A-Za-z0-9]+\z/) && invoice['status'] == 'paid' &&
          invoice['currency'] == 'jpy' && [0].include?(invoice['amount_remaining'])
      end

      def complete_list?(list)
        list.is_a?(Hash) && list['has_more'] == false && list['data'].is_a?(Array)
      end

      def paid_line?(item)
        lines = invoice['lines']
        return false unless complete_list?(lines)

        selected = lines['data'].select { |line| matches_item?(line, item) }
        selected.size == 1 && valid_line_period?(selected.first, item)
      end

      def matches_item?(line, item)
        details = line.dig('parent', 'subscription_item_details') || {}
        (details['subscription_item'] || line['subscription_item']) == item['id'] &&
          (line.dig('pricing', 'price_details', 'price') || line.dig('price', 'id')) == @contract['stripe_price_id'] &&
          valid_amount?(line)
      end

      def valid_amount?(line)
        line['quantity'] == 1 && line['amount'].is_a?(Integer) && line['amount'] >= 0
      end

      def valid_line_period?(line, item)
        start_at, end_at = period(item)
        start_line = line.dig('period', 'start')
        timestamp?(start_at) && timestamp?(end_at) && end_at > start_at && timestamp?(start_line) &&
          start_line >= start_at && start_line < end_at && line.dig('period', 'end') == end_at
      end

      def period(item)
        [item['current_period_start'] || @subscription['current_period_start'], item['current_period_end'] || @subscription['current_period_end']]
      end

      def build(item)
        starts_at, ends_at = period(item)
        anchor = @subscription['billing_cycle_anchor']
        return unless timestamp?(anchor) && anchor <= starts_at && %w[month year].include?(@contract['cycle'])

        @contract.slice('plan_id', 'plan_version', 'cycle').merge(
          'subscription_id' => @subscription.fetch('id'), 'stripe_price_id' => @contract.fetch('stripe_price_id'),
          'invoice_id' => invoice.fetch('id'), 'paid_at' => invoice.dig('status_transitions', 'paid_at'),
          'term_start' => starts_at, 'term_end' => ends_at, 'anchor' => anchor,
          'normal_limit' => @contract.dig('entitlements', 'limits', 'ai_generations')
        )
      end

      def timestamp?(value)
        value.is_a?(Integer) && value.positive?
      end
    end
  end
end
