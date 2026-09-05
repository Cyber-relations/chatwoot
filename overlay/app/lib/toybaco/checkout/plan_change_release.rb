# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Checkout
    module PlanChangeRelease
      private

      def cancellation_fingerprint(receipt)
        digest(receipt.slice('schedule_id', 'schedule_fingerprint', 'created_fingerprint', 'quote'))
      end

      def schedule_state(sub, receipt)
        if receipt['status'] == 'reserved'
          return { 'status' => 'effective' } if configured_target?(sub, receipt) && !schedule_id(sub)

          verified_schedule(sub, receipt)
          return { 'status' => 'effective' } if now >= receipt.dig('quote', 'period_end')

          { 'cancellation_token' => cancellation_fingerprint(receipt) }
        elsif %w[created configuring].include?(receipt['status'])
          { 'cancellation_token' => cancellation_fingerprint(receipt) }
        else
          {}
        end
      end

      def release_reservation(receipt, applied: false)
        sub = subscription
        schedule = @client.retrieve_subscription_schedule(receipt.fetch('schedule_id'))
        if released_by_stripe?(sub, schedule, receipt)
          receipt['release_result'] ||= release_result(applied)
          return finish_release(receipt)
        end
        validate_release!(sub, schedule, receipt)
        reject!('changed') if !applied && now >= receipt.dig('quote', 'period_end')
        receipt['status'] = 'releasing'
        receipt['release_result'] = release_result(applied)
        save_receipt(receipt)
        @client.release_subscription_schedule(receipt.fetch('schedule_id'), idempotency_key: operation_key(receipt, 'release'))
        reject!('review') if schedule_id(subscription)
        finish_release(receipt)
      end

      def validate_release!(sub, schedule, receipt)
        reject!('schedule_conflict') unless schedule_id(sub) == receipt['schedule_id'] && !sub['pending_update']
        return verified_schedule(sub, receipt) if receipt['schedule_fingerprint']

        reject!('schedule_conflict') unless schedule_fingerprint(schedule) == receipt['created_fingerprint'] && schedule['status'] == 'active'
      end

      def released_by_stripe?(sub, schedule, receipt)
        return false if schedule_id(sub) || %w[released completed].include?(schedule['status']) == false

        id = receipt.dig('quote', 'subscription_id')
        return false unless [schedule['subscription'], schedule['released_subscription']].include?(id)

        bound = schedule.merge('subscription' => id)
        expected = receipt.values_at('schedule_fingerprint', 'created_fingerprint').compact.first
        reject!('schedule_conflict') unless schedule_fingerprint(bound) == expected
        return true if receipt['status'] == 'releasing'

        reject!('changed') unless configured_target?(sub, receipt)
        true
      end

      def release_result(applied)
        applied ? 'applied' : 'released'
      end

      def finish_release(receipt)
        if receipt['release_result'] == 'applied'
          outcome = SubscriptionSync.new(client: @client, catalog: @catalog).call(@account, subscription_id: receipt.dig('quote', 'subscription_id'))
          reject!('review') unless outcome == 'applied'
        end
        receipt['status'] = receipt.fetch('release_result')
        save_receipt(receipt)
        { 'status' => receipt['status'] }
      end
    end
  end
end
