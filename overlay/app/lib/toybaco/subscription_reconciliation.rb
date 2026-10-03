# frozen_string_literal: true

require_relative 'growth/period_end_cancel'

module Toybaco::SubscriptionReconciliation
  class Invalid < StandardError; end
  class NotProvisioned < StandardError; end
  # The suspension Sync changed more than the suspension (Processing#suspend_unchanged).
  class SuspensionChanged < StandardError; end
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

  # An attention request whose store still skips the suspension for a Free return that
  # never finished: the bound store is active and still holds this subscription, with its
  # unfinished cancel journal or, before any journal, the Sync's mark of the skipped
  # suspension. Only durable facts count, so a lost or failed suspension in the attention
  # run is retried by the sweep until it commits, behind a renewal barrier held only by
  # terminal attention dispatch rows too (Execution#suspend_behind_barrier, unless a renewal
  # coordinator is pending); a re-armed request is not. Neither is an
  # attention that waits for its subscription's renewal dispatch while a dispatch row can still
  # re-arm it (result renewal_pending, rearming_dispatch?): that dispatch re-arms it when
  # it completes (rearm_waiting!), and a store in the middle of its renewal, a grace before its
  # due date included, is never suspended for it. The sweep's SQL
  # (SubscriptionReconciliationSweepJob#suspension_candidates) mirrors all of this.
  def suspension_due?(record)
    return false unless suspension_request?(record)

    account = Account.find_by(id: record.account_id)
    attrs = account&.internal_attributes
    return false unless account&.active? && attrs.is_a?(Hash)

    rules = Toybaco::Growth::PeriodEndCancel
    rules.return_latched?(attrs, record.subscription_id) || rules.suspension_skipped?(attrs, record.subscription_id)
  end

  # A bound attention request, unless it waits for a renewal dispatch of its subscription that
  # can still re-arm it. A renewal_pending with no such dispatch (only attention rows, or rows
  # that already finished), such as a re-armed request that expired unrun, has nothing that
  # would re-arm it and falls back to the suspension.
  def suspension_request?(record)
    return false unless record.state == 'attention' && !record.account_id.nil?

    !(record.result == 'renewal_pending' && rearming_dispatch?(record.mode, record.subscription_id))
  end

  # Renewal dispatch rows of the subscription that can still reach enqueue_sync!, which re-arms
  # a waiting request (rearm_waiting!), from the transitions of Growth::RenewalDispatchExecution
  # and the rows Growth::RenewalDispatchQueue.sweep takes: a pending row is claimed when due, a
  # running row when its lease ends, and an idle grace_ready row at its due_at (before or after
  # it; a newer fact also turns it pending again). An attention row is never claimed again, and
  # an idle paid_ready or free_completed row enqueued the Sync when it finished, inside the same
  # dispatch lock. Unlike Growth::RenewalDispatch.blocked?, the barrier for the Sync, this only
  # tells whether a renewal_pending request still has a dispatch that would re-arm it.
  def rearming_dispatch?(mode, subscription_id)
    rows = Toybaco::GrowthRenewalDispatch.joins('JOIN toybaco_renewal_operations o ON o.id = toybaco_growth_renewal_dispatches.renewal_operation_id')
                                         .where('o.mode = ? AND o.subscription_id = ?', mode, subscription_id)
    rows.where(state: %w[pending running]).or(rows.where(state: 'idle', phase: 'grace_ready')).exists?
  end
end

require_relative 'subscription_reconciliation/dispatch'
