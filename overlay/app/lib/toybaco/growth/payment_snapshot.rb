# frozen_string_literal: true

require_relative 'payment_signature'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class PaymentSnapshot
      REFUNDS = %w[charge.refunded charge.dispute.created charge.dispute.closed].freeze
      SESSION_FIELDS = %w[id mode payment_status customer payment_intent client_reference_id livemode].freeze
      METADATA_FIELDS = %w[toybaco_item toybaco_plan_version toybaco_generations toybaco_expiry_days toybaco_pack_account_id
                           toybaco_pack_nonce toybaco_billing_owner_id toybaco_reference_price_id].freeze

      def initialize(event, environment: ENV, now: Time.now.utc)
        @event = event
        @environment = environment
        @now = now
      end

      def read
        verify_event!
        object = @event.dig('data', 'object')
        raise PaymentSignature::Invalid unless object.is_a?(Hash)

        return checkout(object) if @event['type'] == 'checkout.session.completed'
        return refund(object) if REFUNDS.include?(@event['type'])
        return renewal_failure(object) if @event['type'] == 'invoice.payment_failed'

        nil
      end

      private

      def verify_event!
        mode = @environment.fetch('TOYBACO_STRIPE_MODE', 'live')
        raise PaymentSignature::Invalid unless %w[live test].include?(mode) && valid_identity?(mode)
        raise PaymentSignature::Invalid unless @event['created'].is_a?(Integer) && @event['created'].between?(1, @now.to_i)
        raise PaymentSignature::Invalid if @environment['TOYBACO_DEPLOYMENT_ENVIRONMENT'] == 'staging' && mode != 'test'
      end

      def valid_identity?(mode)
        @event.is_a?(Hash) && @event['object'] == 'event' && @event['account'].nil? &&
          @event['livemode'] == (mode == 'live') && @event['id'].to_s.match?(/\Aevt_[A-Za-z0-9]+\z/)
      end

      def checkout(object)
        return unless object['mode'] == 'payment' && object.dig('metadata', 'toybaco_item') == 'ai_pack' && object['payment_status'] == 'paid'
        raise PaymentSignature::Invalid unless object['id'].to_s.match?(/\Acs_(?:test_|live_)?[A-Za-z0-9]+\z/)

        selected = object.slice(*SESSION_FIELDS).merge('metadata' => object.fetch('metadata').slice(*METADATA_FIELDS))
        build('pack_checkout', object['id'], selected)
      end

      def refund(object)
        reference = @event['type'] == 'charge.refunded' ? object['id'] : object['charge']
        raise PaymentSignature::Invalid unless reference.to_s.match?(/\Ach_[A-Za-z0-9]+\z/)

        build('pack_refund', reference, { 'id' => object['id'], 'charge' => reference })
      end

      def renewal_failure(object)
        return unless object['billing_reason'] == 'subscription_cycle'

        subscription = object['subscription'] || object.dig('parent', 'subscription_details', 'subscription')
        return unless subscription

        verify_renewal_identity!(object, subscription)

        selected = object.slice('id', 'object', 'customer', 'billing_reason', 'attempt_count').merge('subscription' => subscription)
        build('renewal_failure', object['id'], selected)
      end

      def verify_renewal_identity!(object, subscription)
        valid = object['object'] == 'invoice' && object['id'].to_s.match?(/\Ain_[A-Za-z0-9]+\z/) &&
                subscription.to_s.match?(/\Asub_[A-Za-z0-9]+\z/) && object['customer'].to_s.match?(/\Acus_[A-Za-z0-9]+\z/) &&
                object['attempt_count'].is_a?(Integer) && object['attempt_count'].positive?
        raise PaymentSignature::Invalid unless valid
      end

      def build(action, reference, object)
        snapshot = @event.slice('id', 'object', 'type', 'created', 'livemode').merge('data' => { 'object' => object })
        { action: action, reference_id: reference, event_id: @event['id'], snapshot: snapshot }
      end
    end
  end
end
