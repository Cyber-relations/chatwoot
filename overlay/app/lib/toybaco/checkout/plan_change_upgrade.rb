# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Checkout
    module PlanChangeUpgrade
      private

      def pending_upgrade(sub, receipt)
        pending = sub.dig('pending_update', 'subscription_items')
        reject!('schedule_conflict') unless pending.is_a?(Array) && pending.length == 1
        target = pending.first
        actual = [target['id'], object_id_value(target['price']), target['quantity']]
        expected = [receipt.dig('quote', 'item_id'), receipt.dig('quote', 'target_price'), 1]
        reject!('schedule_conflict') unless actual == expected
        receipt['status'] = 'payment_pending'
        save_receipt(receipt)
        receipt_state(sub, receipt)
      end

      def execute_upgrade(sub, receipt)
        quote = receipt.fetch('quote')
        params = item_update(quote).merge('payment_behavior' => 'pending_if_incomplete', 'proration_behavior' => 'always_invoice',
                                          'proration_date' => quote.fetch('created_at'))
        @client.update_subscription(sub.fetch('id'), params, idempotency_key: operation_key(receipt, 'upgrade'))
        sub = subscription
        return finish_upgrade(sub, receipt) if paid_target?(sub, receipt)

        receipt['status'] = sub['pending_update'] ? 'payment_pending' : 'review'
        save_receipt(receipt)
        receipt_state(sub, receipt)
      end
    end
  end
end
