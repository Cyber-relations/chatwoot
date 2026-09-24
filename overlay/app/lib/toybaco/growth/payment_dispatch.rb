# frozen_string_literal: true

require 'securerandom'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    module PaymentDispatch
      module_function

      def enqueue(event, now: Time.now.utc, job_class: Toybaco::GrowthPaymentJob)
        token = SecureRandom.hex(24)
        reserved = event.with_lock do
          next false unless due?(event, now)

          event.update!(state: 'queued', lease_token: token, lease_expires_at: nil, next_attempt_at: now + 300)
          true
        end
        return unless reserved

        queued = job_class.perform_later(event.id)
        raise ActiveJob::EnqueueError unless queued
      rescue StandardError
        release_queue(event, token, now)
        Rails.logger.warn('TOYBACO_PAYMENT_QUEUE_UNAVAILABLE')
        nil
      end

      def release_queue(event, token, now)
        event.with_lock do
          next unless event.state == 'queued' && event.lease_token == token

          event.update!(state: 'pending', lease_token: nil, next_attempt_at: now + 60)
        end
      end

      def due?(event, now)
        return event.lease_expires_at && event.lease_expires_at <= now if event.state == 'processing'

        %w[pending queued].include?(event.state) && event.next_attempt_at <= now
      end
    end
  end
end
