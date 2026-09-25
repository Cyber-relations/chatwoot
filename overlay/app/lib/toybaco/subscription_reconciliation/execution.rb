# frozen_string_literal: true

require 'digest'
require_relative '../subscription_reconciliation'
require_relative '../store_fulfillment'
require_relative '../growth/inbox_retention'
require_relative 'processing'
require_relative '../growth/renewal_dispatch'

class Toybaco::SubscriptionReconciliation::Execution
  include Toybaco::SubscriptionReconciliation::Processing

  def initialize(record, client: nil, now: nil, environment: ENV)
    @record = record
    @client = client
    @fixed_now = now
    @environment = environment
  end

  def call
    raise Toybaco::SubscriptionReconciliation::Invalid if Account.connection.transaction_open?

    Account.connection_pool.with_connection do |connection|
      key = Digest::SHA256.digest("toybaco:subscription-reconciliation:#{@record.mode}:#{@record.subscription_id}").unpack1('q>')
      acquired = Account.uncached { connection.select_value("SELECT pg_try_advisory_lock(#{key})") }
      return 'busy' unless acquired

      begin
        return defer_behind_barrier! if renewal_barrier?

        run
      ensure
        Account.uncached { connection.select_value("SELECT pg_advisory_unlock(#{key})") }
      end
    end
  end

  private

  def now
    @fixed_now || Time.now.utc
  end

  # Dispatch progress beyond 'received', a started N2 or a due grace row keeps the whole
  # Sync out. Otherwise a blocked subscription runs only the status-only Sync.
  def renewal_barrier?
    dispatch = Toybaco::Growth::RenewalDispatch
    dispatch.blocked?(@record.mode, @record.subscription_id, now: now) &&
      !dispatch.repair_admissible?(@record.mode, @record.subscription_id, now: now)
  end

  # Only the retry slot moves, so the sweep does not re-enqueue the request every tick.
  # Attempts stay. A pending request at its deadline ends in attention with the same
  # expiry rule as claim!; a running one (a crash inside a claim) is left to claim!.
  def defer_behind_barrier!
    @record.with_lock do
      next unless Toybaco::SubscriptionReconciliation::STATES.include?(@record.state)

      if @record.state == 'pending' && @record.deadline_at <= now
        @record.update!(state: 'attention', result: expired_result)
        Rails.logger.error('TOYBACO_SUBSCRIPTION_SYNC_ATTENTION')
      else
        @record.update!(next_attempt_at: deferred_slot, next_enqueue_at: now + 60)
      end
    end
    @record.state == 'attention' ? 'attention' : 'renewal_pending'
  end

  # The deferral writes now + 60 without a due check, so inside the claim's own microsecond
  # (the column keeps microseconds) it would write the claim's slot again. A running row's
  # slot therefore always moves past the stored one, which ends the claim generation of a
  # worker that lost its session lock (current_claim?). A pending row takes now + 60.
  def deferred_slot
    slot = now + 60
    return slot unless @record.state == 'running' && slot.floor(6) <= @record.next_attempt_at

    @record.next_attempt_at + Rational(1, 1_000_000)
  end

  def run
    return @record.reload.state unless claim!

    result = reconcile
    return renewal_pending! if result == 'renewal_pending'
    return retry_later!('free_return_pending') if result == 'free_return_pending'

    finish!(%w[applied payment_pending].include?(result) ? 'completed' : result, result)
  rescue Toybaco::Growth::InboxRetention::Busy, ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked
    retry_later!('writer_busy')
  rescue Toybaco::SubscriptionReconciliation::NotProvisioned
    retry_later!('not_provisioned')
  rescue Toybaco::SubscriptionReconciliation::Invalid, Toybaco::Growth::InboxRetention::Invalid,
         Toybaco::SubscriptionSync::Unresolved, Toybaco::StoreFulfillment::Unavailable
    finish!('attention', 'binding_unresolved')
  rescue StandardError
    raise unless @revision

    retry_later!('processing_unavailable')
  end

  def claim!
    @record.with_lock do
      next false unless Toybaco::SubscriptionReconciliation.due?(@record, now)

      if @record.attempts >= Toybaco::SubscriptionReconciliation::ATTEMPTS || @record.deadline_at <= now
        next reclaim_orphan! if orphan_rearmable?

        @record.update!(state: 'attention', result: expired_result)
        next false
      end

      @revision = @record.requested_revision
      @record.update!(state: 'running', attempts: @record.attempts + 1, next_attempt_at: now + 60)
      @lease = @record.next_attempt_at
      true
    end
  end

  # claim! holds the session lock, so a running row here lost its worker, and a dispatch
  # completion that found it running could not re-arm it. When it only waited for renewal
  # dispatch and the barrier is down, the expiry re-arms and claims it in one step. An
  # expired pending row keeps its attention: a dispatch completion re-arms pending rows.
  def orphan_rearmable?
    @record.state == 'running' && Toybaco::SubscriptionReconciliation.waiting_cause?(@record) && !renewal_barrier?
  end

  def reclaim_orphan!
    @revision = @record.requested_revision
    @record.update!(Toybaco::SubscriptionReconciliation.rearm_values(now).merge(state: 'running', attempts: 1, next_attempt_at: now + 60))
    @lease = @record.next_attempt_at
    true
  end

  # Shared by claim! and the pre-claim barrier. An expiry keeps the waiting cause only
  # when no real failure spent the budget (SubscriptionReconciliation.waiting_cause?);
  # the next notification or dispatch completion can then re-arm it. Otherwise retry_limit.
  def expired_result
    Toybaco::SubscriptionReconciliation.waiting_cause?(@record) ? 'renewal_pending' : 'retry_limit'
  end

  def retry_later!(reason)
    finish!('pending', reason)
  end

  # The fresh subscription showed a renewal period whose signed invoice fact has
  # not reached its dispatch phase. Waiting keeps the retry budget and deadline.
  def renewal_pending!
    state = finish!('pending', 'renewal_pending')
    state == 'pending' ? 'renewal_pending' : state
  end

  def finish!(state, result)
    @record.with_lock do
      raise Toybaco::SubscriptionReconciliation::Invalid unless current_claim?

      values = completion_values(state, result)
      @record.update!(values)
      Rails.logger.error('TOYBACO_SUBSCRIPTION_SYNC_ATTENTION') if values[:state] == 'attention'
      @record.state
    end
  end

  # The claim generation: claim! and reclaim_orphan! keep the retry slot they wrote as the
  # row stores it (the column drops sub-microsecond digits of the value passed in). A worker
  # that lost its session lock can outlive its claim. Any re-claim runs at or after that
  # slot and writes a later one, so the old worker finishes nothing. Only session-lock
  # holders write a running row's slot, so the lease never refuses a worker that keeps it.
  def current_claim?
    @record.state == 'running' && @revision && @lease && @record.next_attempt_at == @lease
  end

  def completion_values(state, result)
    values = { state: state, result: result }
    if %w[completed superseded].include?(state)
      values[:completed_revision] = @revision
      values[:completed_at] = now
      values[:state] = 'pending' if @record.requested_revision > @revision
    end
    pending_values(values, result) if values[:state] == 'pending'
    values
  end

  def pending_values(values, result)
    values[:attempts] = [@record.attempts - 1, 0].max if result == 'renewal_pending'
    attempts = values.fetch(:attempts, @record.attempts)
    if attempts >= Toybaco::SubscriptionReconciliation::ATTEMPTS || @record.deadline_at <= now
      return values.merge!(Toybaco::SubscriptionReconciliation.rearm_values(now)) if lifted_wait?(result, attempts)

      values[:state] = 'attention'
    end
    delay = retry_delay(result)
    values[:next_attempt_at] = now + delay
    values[:next_enqueue_at] = now + delay
  end

  # The guard made this run wait behind the barrier (:wait) and the barrier is down at its
  # expiry. The dispatch can only progress meanwhile if this worker lost its session lock,
  # and its completion then found the row running, so the expiry re-arms it. A status-only
  # wait never had the barrier up and still ends in attention at its deadline.
  def lifted_wait?(result, attempts)
    result == 'renewal_pending' && @renewal_decision == :wait && attempts < Toybaco::SubscriptionReconciliation::ATTEMPTS &&
      !renewal_barrier?
  end

  def retry_delay(result)
    return 60 if result == 'renewal_pending'
    return 0 if %w[applied payment_pending superseded].include?(result)

    [30 * (2**[@record.attempts - 1, 5].min), 900].min
  end
end
