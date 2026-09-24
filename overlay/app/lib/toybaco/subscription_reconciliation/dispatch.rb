# frozen_string_literal: true

module Toybaco::SubscriptionReconciliation::Dispatch
  module_function

  def enqueue(record, now: Time.now.utc)
    reserved = record.with_lock do
      next false unless Toybaco::SubscriptionReconciliation.due?(record, now) && record.next_enqueue_at <= now

      record.update!(next_enqueue_at: now + 60)
      true
    end
    return unless reserved

    queued = Toybaco::SubscriptionReconciliationJob.perform_later(record.id)
    raise ActiveJob::EnqueueError unless queued

    queued
  rescue StandardError
    # The enqueue response may be lost after Redis accepted it. Keep the
    # reservation; the durable sweep can retry after one minute. Execution
    # is protected by a session lock and a completed revision, not job_id.
    Rails.logger.warn('TOYBACO_SUBSCRIPTION_SYNC_QUEUE_UNAVAILABLE')
    nil
  end
end
