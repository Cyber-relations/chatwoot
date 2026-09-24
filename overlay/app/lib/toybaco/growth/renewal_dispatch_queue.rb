# frozen_string_literal: true

require_relative 'renewal_dispatch'

module Toybaco::Growth::RenewalDispatchQueue
  Dispatch = Toybaco::Growth::RenewalDispatch

  module_function

  def enqueue(row, now: Time.now.utc)
    raise Dispatch::Invalid if Account.connection.transaction_open?

    reserved = row.with_lock do
      next false unless Dispatch.due?(row, now) && row.next_enqueue_at <= now

      row.update!(next_enqueue_at: now + 60)
      true
    end
    return unless reserved

    queued = Toybaco::GrowthRenewalDispatchJob.perform_later(row.id)
    raise ActiveJob::EnqueueError unless queued

    queued
  rescue Dispatch::Invalid
    raise
  rescue StandardError
    Rails.logger.warn('TOYBACO_RENEWAL_DISPATCH_QUEUE_UNAVAILABLE')
    nil
  end

  def sweep(now: Time.now.utc)
    rows = Dispatch.model
    pending = rows.where(state: 'pending').where('next_attempt_at <= ?', now)
    stale = rows.where(state: 'running').where('lease_expires_at <= ?', now)
    due = rows.where(state: 'idle', phase: 'grace_ready').where('due_at <= ?', now)
    pending.or(stale).or(due).order(:next_attempt_at, :id).limit(100).each { |row| enqueue(row, now: now) }
    Rails.logger.error('TOYBACO_RENEWAL_DISPATCH_ATTENTION') if rows.exists?(state: 'attention')
  end
end
