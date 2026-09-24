# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/payment_dispatch'
require_relative 'subscription_reconciliation_sweep_job'

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
    # Reuse the deployed cron class. Recovery remains active after opt-in is disabled,
    # without leaving a new recurring job in Redis before the first receipt exists.
    Toybaco::SubscriptionReconciliationSweepJob.perform_now
  end
end
