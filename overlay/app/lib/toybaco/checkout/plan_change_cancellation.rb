# frozen_string_literal: true

require_relative '../billing_cancel'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Checkout
    # Releasing our reservation and cancelling billing are one confirmed operation.
    # Separate durable steps recover after either Stripe response is lost.
    module PlanChangeCancellation
      CANCEL_KEY = 'toybaco_cancel_request'

      def cancel_subscription(reservation_token: nil)
        locked do
          sub = subscription
          return complete_cancellation if sub['cancel_at_period_end'] || sub['status'] == 'canceled'

          intent = cancellation_intent(sub, reservation_token)
          cancel_owned_reservation(intent) if intent['reservation_operation']
          sub = subscription
          reject!('payment_pending') if sub['pending_update']
          reject!('schedule_conflict') if schedule_id(sub)
          @client.update_subscription(sub.fetch('id'), Toybaco::BillingCancel.period_end_params,
                                      idempotency_key: "toybaco-cancel-#{@account.id}-#{intent.fetch('operation')}")
          reject!('review') unless subscription['cancel_at_period_end'] == true

          complete_cancellation
        end
      end

      private

      def complete_cancellation
        intent = attrs[CANCEL_KEY]
        save_cancellation(intent.merge('status' => 'complete')) if intent
        { 'cancelled' => true }
      end

      def active_cancellation?
        attrs.dig(CANCEL_KEY, 'status') == 'requested'
      end

      def save_cancellation(intent)
        @account.with_lock { @account.update!(internal_attributes: attrs.merge(CANCEL_KEY => intent)) }
      end

      def cancellation_intent(sub, token)
        saved = attrs[CANCEL_KEY]
        if saved && saved['status'] == 'requested'
          reject!('review') unless saved['subscription_id'] == sub['id'] && now < saved['created_at'] + (23 * 3600)
          return saved
        end
        reject!('payment_pending') if sub['pending_update']
        receipt = attrs[PlanChange::RECEIPT_KEY]
        validate_cancel_reservation!(sub, receipt, token)
        intent = { 'operation' => SecureRandom.uuid, 'subscription_id' => sub.fetch('id'), 'created_at' => now, 'status' => 'requested' }
        intent['reservation_operation'] = receipt.dig('quote', 'operation') if schedule_id(sub)
        save_cancellation(intent)
        intent
      end

      def validate_cancel_reservation!(sub, receipt, token)
        unless schedule_id(sub)
          reject!('busy') if active_receipt?
          return
        end
        reject!('schedule_conflict') unless receipt && receipt['schedule_id'] == schedule_id(sub)
        reject!('changed') unless token == cancellation_fingerprint(receipt)
        reject!('changed') unless now < receipt.dig('quote', 'period_end')
        schedule = @client.retrieve_subscription_schedule(receipt.fetch('schedule_id'))
        validate_release!(sub, schedule, receipt)
      end

      def cancel_owned_reservation(intent)
        receipt = attrs[PlanChange::RECEIPT_KEY]
        reject!('schedule_conflict') unless receipt && receipt.dig('quote', 'operation') == intent['reservation_operation']
        return if receipt['status'] == 'released'

        release_reservation(receipt)
      end
    end
  end
end
