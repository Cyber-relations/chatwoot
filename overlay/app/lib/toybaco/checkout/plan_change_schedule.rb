# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Checkout
    # Create-from-subscription preserves Stripe's existing defaults. Phase updates
    # must explicitly preserve writable settings; unknown nonempty fields fail closed.
    module PlanChangeSchedule
      OWNER = 'toybaco-plan-change-v1'

      private

      def resume_schedule(receipt)
        sub = subscription
        return release_reservation(receipt, applied: true) if configured_target?(sub, receipt)

        if receipt['status'] == 'reserved'
          verified_schedule(sub, receipt)
          return receipt_state(sub, receipt)
        end
        retry_window!(receipt)
        quote = receipt.fetch('quote')
        revalidate_target!(quote)
        reject!('changed') unless now < quote.fetch('period_end')
        reject!('changed') unless fingerprint(sub.merge('schedule' => nil)) == quote['fingerprint']
        create_schedule(sub, receipt) unless receipt['schedule_id']
        configure_schedule(receipt)
      end

      def create_schedule(sub, receipt)
        reject!('schedule_conflict') if schedule_id(sub) && receipt['status'] != 'creating'
        receipt['status'] = 'creating'
        save_receipt(receipt)
        schedule = @client.create_subscription_schedule(sub.fetch('id'), idempotency_key: operation_key(receipt, 'create'))
        reject!('review') unless schedule['id'].to_s.match?(/\Asub_sched_[A-Za-z0-9]+\z/) && schedule['subscription'] == sub['id']
        receipt['schedule_id'] = schedule.fetch('id')
        receipt['created_fingerprint'] = schedule_fingerprint(schedule)
        receipt['status'] = 'created'
        save_receipt(receipt)
      end

      def configure_schedule(receipt)
        sub = subscription
        reject!('schedule_conflict') unless schedule_id(sub) == receipt['schedule_id'] && !sub['pending_update']
        schedule = @client.retrieve_subscription_schedule(receipt.fetch('schedule_id'))
        # A lost update response may already have installed the intended phases.
        return reserve(schedule, receipt) if receipt['configuration'] && configured_schedule?(schedule, receipt)

        reject!('schedule_conflict') unless schedule_fingerprint(schedule) == receipt['created_fingerprint']
        receipt['configuration'] ||= schedule_params(schedule, receipt)
        receipt['status'] = 'configuring'
        save_receipt(receipt)
        submit_schedule(receipt)
      end

      def submit_schedule(receipt)
        @client.update_subscription_schedule(receipt.fetch('schedule_id'), receipt.fetch('configuration'),
                                             idempotency_key: operation_key(receipt, 'configure'))
        schedule = @client.retrieve_subscription_schedule(receipt.fetch('schedule_id'))
        reject!('review') unless configured_schedule?(schedule, receipt)
        reserve(schedule, receipt)
      end

      def owner_metadata(receipt)
        { 'toybaco_owner' => OWNER, 'toybaco_account_id' => @account.id.to_s,
          'toybaco_subscription_id' => receipt.dig('quote', 'subscription_id'),
          'toybaco_operation' => receipt.dig('quote', 'operation') }
      end

      def reserve(schedule, receipt)
        receipt['schedule_fingerprint'] = schedule_fingerprint(schedule)
        receipt['status'] = 'reserved'
        save_receipt(receipt)
        receipt_state(subscription, receipt)
      end

      def schedule_fingerprint(schedule)
        digest(schedule.slice('subscription', 'metadata', 'phases', 'default_settings', 'end_behavior', 'billing_mode'))
      end

      def verified_schedule(sub, receipt)
        reject!('schedule_conflict') unless schedule_id(sub) == receipt['schedule_id'] && !sub['pending_update']
        schedule = @client.retrieve_subscription_schedule(receipt.fetch('schedule_id'))
        reject!('schedule_conflict') unless schedule['status'] == 'active' && schedule_fingerprint(schedule) == receipt['schedule_fingerprint']
        reject!('schedule_conflict') unless configured_schedule?(schedule, receipt)
        schedule
      end

      def configured_target?(sub, receipt)
        receipt['status'] == 'reserved' && now >= receipt.dig('quote', 'period_end') && paid_target?(sub, receipt)
      end
    end
  end
end
