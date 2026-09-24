# frozen_string_literal: true

require_relative '../../../lib/toybaco/subscription_reconciliation'

class Toybaco::SubscriptionReconciliationSweepJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    now = Time.now.utc
    records = Toybaco::SubscriptionSyncRequest
    records.where(state: Toybaco::SubscriptionReconciliation::STATES)
           .where('next_attempt_at <= ? AND next_enqueue_at <= ?', now, now)
           .order(:next_attempt_at, :id).limit(100).each do |record|
      Toybaco::SubscriptionReconciliation::Dispatch.enqueue(record, now: now)
    end
    Rails.logger.error('TOYBACO_SUBSCRIPTION_SYNC_ATTENTION') if records.exists?(state: 'attention')
  end
end
