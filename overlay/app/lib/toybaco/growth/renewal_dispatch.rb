# frozen_string_literal: true

require 'digest'
require_relative 'renewal_dispatch_sync_guard'

# Admission and synchronization barrier are committed with the signed N1 fact.
# No provider call, model invocation or queue publication occurs in this transaction.
module Toybaco::Growth::RenewalDispatch
  FLAG = 'TOYBACO_RENEWAL_DISPATCH_ENABLED'
  ATTEMPTS = 48
  DEADLINE = 86_400
  Busy = Class.new(StandardError)
  Invalid = Class.new(StandardError)

  module_function

  def model
    Toybaco::GrowthRenewalDispatch
  end

  def lock_key(mode, subscription_id)
    Digest::SHA256.digest("toybaco:subscription-reconciliation:#{mode}:#{subscription_id}").unpack1('q>')
  end

  def admit_lock!(event, environment: ENV)
    enabled = environment[FLAG] == 'true'
    accepted = model.joins('JOIN toybaco_renewal_operations o ON o.id = toybaco_growth_renewal_dispatches.renewal_operation_id')
                    .exists?(['o.mode = ? AND o.subscription_id = ?', event.mode, event.reference_id])
    return unless enabled || accepted
    raise Invalid unless Account.connection.transaction_open?

    key = lock_key(event.mode, event.reference_id)
    raise Busy unless Account.uncached { Account.connection.select_value("SELECT pg_try_advisory_xact_lock(#{key})") }
  end

  def accept!(operation, fact, now:, environment: ENV)
    raise Invalid unless Account.connection.transaction_open?

    row = model.find_by(renewal_operation_id: operation.id)
    return unless row || environment[FLAG] == 'true'

    row ||= model.create!(renewal_operation_id: operation.id, requested_fact_id: fact.id, due_at: operation.due_at,
                          deadline_at: now + DEADLINE, next_attempt_at: now, next_enqueue_at: now)
    row.with_lock { update_request!(row, operation, fact, now) }
    row
  end

  def update_request!(row, operation, fact, now)
    raise Invalid unless fact.renewal_operation_id == row.renewal_operation_id

    values = request_values(row, operation, fact, now)
    shorten_due!(values, row)
    row.update!(values)
  end

  def request_values(row, operation, fact, now)
    values = { requested_fact_id: [row.requested_fact_id, fact.id].max, due_at: [row.due_at, operation.due_at].compact.min }
    if row.state == 'idle' && row.phase == 'grace_ready' && fact.id > row.processed_fact_id
      deadline = [now + DEADLINE, row.due_at && (row.due_at + DEADLINE)].compact.min
      values.merge!(state: 'pending', next_attempt_at: now, next_enqueue_at: now, attempts: 0, deadline_at: deadline)
    end
    values[:processed_fact_id] = values[:requested_fact_id] if row.state == 'idle' && %w[paid_ready free_completed].include?(row.phase)
    values
  end

  def shorten_due!(values, row)
    return unless values[:due_at] && row.due_at && values[:due_at] < row.due_at

    values[:deadline_at] = [values.fetch(:deadline_at, row.deadline_at), values[:due_at] + DEADLINE].min
    values[:next_attempt_at] = [values.fetch(:next_attempt_at, row.next_attempt_at), values[:due_at]].min
  end

  def for_event(event)
    fact = Toybaco::RenewalInvoiceFact.find_by(billing_event_id: event.id)
    fact && model.find_by(renewal_operation_id: fact.renewal_operation_id)
  end

  def blocked?(mode, subscription_id, now:)
    rows = model.joins('JOIN toybaco_renewal_operations o ON o.id = toybaco_growth_renewal_dispatches.renewal_operation_id')
                .where('o.mode = ? AND o.subscription_id = ?', mode, subscription_id)
    return true if rows.where.not(state: 'idle').exists?

    rows.where(state: 'idle', phase: 'grace_ready').exists?(['toybaco_growth_renewal_dispatches.due_at <= ?', now])
  end

  # A blocked subscription may still take the status-only Sync, repairing a stale billing
  # flag, while every unfinished row is still 'received' and N2 has not started. A due
  # grace row keeps the whole Sync out.
  def repair_admissible?(mode, subscription_id, now:)
    rows = model.joins('JOIN toybaco_renewal_operations o ON o.id = toybaco_growth_renewal_dispatches.renewal_operation_id')
                .where('o.mode = ? AND o.subscription_id = ?', mode, subscription_id)
    unfinished = rows.where.not(state: 'idle')
    return false if unfinished.where.not(phase: 'received').exists? ||
                    Toybaco::GrowthRenewalCoordinator.exists?(renewal_operation_id: unfinished.select(:renewal_operation_id))

    !rows.where(state: 'idle', phase: 'grace_ready').exists?(['toybaco_growth_renewal_dispatches.due_at <= ?', now])
  end

  # Webhook SubscriptionSync only: runs after its fresh provider read and before any
  # write, under the subscription session lock that dispatch execution also takes.
  # Re-decides with one `now`: nil (full Sync), :status_only (two status fields) or
  # :wait (write nothing). A blocked subscription that is not repair-admissible waits,
  # also in an exempt ended state (a due crossed during the provider read waits for
  # N2 to close its row); otherwise an exempt ended state takes the full Sync.
  def guard_sync!(account, subscription, now:, environment: ENV)
    mode = subscription['livemode'] ? 'live' : 'test'
    exempt = Toybaco::Growth::RenewalDispatchSyncGuard.new(account, subscription, environment: environment).exempt?
    if blocked?(mode, subscription['id'], now: now)
      return :wait unless repair_admissible?(mode, subscription['id'], now: now)

      exempt ? nil : :status_only
    elsif !exempt && sync_pending?(account, subscription, environment: environment)
      :status_only
    end
  end

  def sync_pending?(account, subscription, environment: ENV)
    Toybaco::Growth::RenewalDispatchSyncGuard.new(account, subscription, environment: environment).pending?
  end

  def due?(row, now)
    return false if row.state == 'attention'
    return row.lease_expires_at <= now if row.state == 'running'
    return row.phase == 'grace_ready' && row.due_at && row.due_at <= now if row.state == 'idle'

    row.next_attempt_at <= now
  end

  def request_id(operation, kind)
    Toybaco::Growth::BillingReceipt.snapshot_digest(['ordinary-renewal-dispatch-v1', operation.id, operation.mode,
                                                     operation.subscription_id, operation.invoice_id, kind])
  end
end
