# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/payment_dispatch'

class Toybaco::GrowthPaymentSweepJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    now = Time.now.utc
    events = Toybaco::GrowthPaymentEvent
    pending = events.where(state: %w[pending queued]).where('next_attempt_at <= ?', now)
    stale = events.where(state: 'processing').where('lease_expires_at <= ?', now)
    pending.or(stale).order(:next_attempt_at, :id).limit(100).each do |event|
      Toybaco::Growth::PaymentDispatch.enqueue(event, now: now)
    end
    Rails.logger.error('TOYBACO_PAYMENT_ATTENTION pending_receipts=true') if events.exists?(state: 'attention')
  end
end
