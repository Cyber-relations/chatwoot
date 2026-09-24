# frozen_string_literal: true

module Toybaco::SubscriptionReconciliation
  class Invalid < StandardError; end
  class NotProvisioned < StandardError; end
  STATES = %w[pending running].freeze
  DEADLINE = 86_400
  ATTEMPTS = 48

  module_function

  def enabled?
    ENV['TOYBACO_SUBSCRIPTION_RECONCILIATION_ENABLED'] == 'true'
  end

  def request!(subscription_id, mode: ENV.fetch('TOYBACO_STRIPE_MODE', ''), now: Time.now.utc)
    raise Invalid unless subscription_id.is_a?(String) && subscription_id.match?(/\Asub_[A-Za-z0-9]{1,200}\z/) && %w[test live].include?(mode)
    raise Invalid if Account.connection.transaction_open?

    record = Account.transaction { persist_request!(subscription_id, mode: mode, now: now) }
    Dispatch.enqueue(record, now: now)
    record.reload
  end

  # Internal admission only: callers must commit the source-event/revision binding
  # in this transaction and enqueue after commit. No provider work runs here.
  def persist_request!(subscription_id, mode:, now:)
    raise Invalid unless Account.connection.transaction_open?

    record = Toybaco::SubscriptionSyncRequest.create_or_find_by!(subscription_id: subscription_id, mode: mode) do |row|
      ids = accounts_for(subscription_id).limit(2).pluck(:id)
      raise Invalid if ids.size > 1

      row.account_id = ids.first
      row.deadline_at = now + DEADLINE
      row.next_attempt_at = row.next_enqueue_at = now
    end
    record.with_lock { refresh_request!(record, now) } unless record.previously_new_record?
    record
  end

  def refresh_request!(record, now)
    # A duplicate notification must not reset an outstanding retry budget. An attention
    # reached only by waiting for renewal dispatch is re-armed by the next notification.
    return if record.state == 'attention' && record.result != 'renewal_pending'

    values = { requested_revision: record.requested_revision + 1 }
    values.merge!(rearm_values(now)) unless STATES.include?(record.state)
    record.update!(values)
  end

  # Renewal dispatch completion re-arms a request that only waits for it, like a new
  # notification does: an attention whose wait ended in renewal_pending, or a pending one
  # with a waiting cause whatever its deadline, so a last retry slot past the deadline
  # cannot strand it. Running requests and real failures stay.
  def rearm_waiting!(record, now:)
    record.with_lock do
      next false unless rearmable?(record)

      record.update!(rearm_values(now).merge(requested_revision: record.requested_revision + 1))
      true
    end
  end

  def rearmable?(record)
    return record.result == 'renewal_pending' if record.state == 'attention'

    record.state == 'pending' && waiting_cause?(record)
  end

  # Only waiting for renewal dispatch stopped the request: no real failure result and
  # retry budget left. Its expiry is renewal_pending, which may be re-armed.
  def waiting_cause?(record)
    [nil, 'renewal_pending'].include?(record.result) && record.attempts < ATTEMPTS
  end

  def rearm_values(now)
    { state: 'pending', attempts: 0, deadline_at: now + DEADLINE, next_attempt_at: now, next_enqueue_at: now, completed_at: nil, result: nil }
  end

  def accounts_for(subscription_id)
    Account.where("internal_attributes ->> 'toybaco_subscription_id' = ?", subscription_id).order(:id)
  end

  def due?(record, now)
    STATES.include?(record.state) && record.next_attempt_at <= now
  end
end

require_relative 'subscription_reconciliation/dispatch'
