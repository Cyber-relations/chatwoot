# frozen_string_literal: true

require_relative 'payment_client'
require_relative 'pack_fulfillment'
require_relative 'pack_refund'
require_relative 'payment_dispatch'
require_relative 'renewal_failure_receipt'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class PaymentExecution
      def initialize(event, client: nil, now: Time.now.utc)
        @event = event
        @client = client
        @now = now
      end

      def call
        @token = claim
        return unless @token

        finish!('completed', reconcile)
      rescue PurchaseIntent::Unavailable, PaymentSignature::Invalid
        fail!('payment_mismatch', final: true)
      rescue ActiveRecord::RecordNotFound
        fail!('record_missing', final: true)
      rescue StandardError
        fail!('provider_or_processing_unavailable', final: false)
      end

      private

      def claim
        @event.with_lock do
          allowed = @event.state == 'queued' || PaymentDispatch.due?(@event, @now)
          next unless allowed

          token = SecureRandom.hex(24)
          @event.update!(state: 'processing', attempts: @event.attempts + 1, lease_token: token, lease_expires_at: @now + 300)
          token
        end
      end

      def reconcile
        client = @client || Checkout::Client.new(ENV.fetch('TOYBACO_STRIPE_KEY', ''))
        return RenewalFailureReceipt.new(@event, client: client, now: @now).record! if @event.action == 'renewal_failure'

        if @event.action == 'pack_checkout'
          verified = PaymentClient.new(client, @event.snapshot)
          PackFulfillment.new(client: verified).complete!(@event.reference_id, @event.event_id)
        else
          PackRefund.new(client: client).call(@event.reference_id)
        end
      end

      def fail!(result, final:)
        raise 'payment receipt could not be claimed' unless @token

        state = final || @event.attempts >= @event.attempt_limit ? 'attention' : 'pending'
        finish!(state, result)
        Rails.logger.error("TOYBACO_PAYMENT_ATTENTION receipt=#{@event.id}") if state == 'attention'
      end

      def finish!(state, result)
        @event.with_lock do
          next unless @event.state == 'processing' && @event.lease_token == @token

          delay = [30 * (2**[@event.attempts - 1, 7].min), 3600].min
          @event.update!(state: state, result: result, lease_token: nil, lease_expires_at: nil,
                         completed_at: state == 'completed' ? Time.now.utc : nil, next_attempt_at: @now + delay)
        end
      end
    end
  end
end
