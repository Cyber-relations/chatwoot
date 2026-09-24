# frozen_string_literal: true

require_relative 'renewal_dispatch_queue'
require_relative 'renewal_dispatch_work'
require_relative 'billing_subscription'

class Toybaco::Growth::RenewalDispatchExecution
  Dispatch = Toybaco::Growth::RenewalDispatch

  def initialize(row, client: nil, environment: ENV, clock: -> { Time.now.utc }, worker: nil)
    @row = row
    @environment = environment
    @clock = clock
    @client = client
    @worker = worker
  end

  def call
    raise Dispatch::Invalid if Account.connection.transaction_open?

    operation = Toybaco::RenewalOperation.find(@row.renewal_operation_id)
    key = Dispatch.lock_key(operation.mode, operation.subscription_id)
    connection = Account.connection
    acquired = Account.uncached { connection.select_value("SELECT pg_try_advisory_lock(#{key})") }
    return 'busy' unless acquired

    begin
      execute
    ensure
      Account.uncached { connection.select_value("SELECT pg_advisory_unlock(#{key})") }
    end
  end

  private

  def execute
    return @row.reload.state unless claim!

    phase = work.call
    finish!(phase)
    enqueue_sync! if %w[grace_ready paid_ready free_completed].include?(phase)
    @row.state
  rescue Toybaco::Growth::RenewalDispatchWork::Attention => e
    fail!(e.message, final: true)
  rescue StandardError
    raise unless @token

    fail!('processing_unavailable', final: false)
  end

  def work
    return @worker if @worker

    client = @client || Toybaco::Checkout::Client.new(@environment.fetch('TOYBACO_STRIPE_KEY', ''))
    Toybaco::Growth::RenewalDispatchWork.new(@row, client: client, environment: @environment, clock: @clock)
  end

  def claim!
    @row.with_lock do
      next false unless Dispatch.due?(@row, @clock.call)

      if @row.attempts >= Dispatch::ATTEMPTS || @row.deadline_at <= @clock.call
        @row.update!(state: 'attention', result: 'retry_limit', lease_token: nil, lease_expires_at: nil)
        next false
      end
      @fact_id = @row.requested_fact_id
      @token = SecureRandom.hex(24)
      @row.update!(state: 'running', attempts: @row.attempts + 1, lease_token: @token, lease_expires_at: @clock.call + 300)
      true
    end
  end

  def finish!(phase)
    raise Dispatch::Invalid unless %w[grace_ready paid_ready due_waiting provider_closed free_completed].include?(phase)

    @row.with_lock do
      ownership!
      terminal = %w[grace_ready paid_ready free_completed].include?(phase)
      now = @clock.call
      values = { state: terminal ? 'idle' : 'pending', phase: phase, result: phase, processed_fact_id: @fact_id,
                 lease_token: nil, lease_expires_at: nil, next_attempt_at: now + 60, next_enqueue_at: now + 60 }
      if phase == 'grace_ready'
        due = Toybaco::RenewalOperation.find(@row.renewal_operation_id).due_at
        raise Dispatch::Invalid unless due && due > now

        values.merge!(due_at: due, next_attempt_at: due, next_enqueue_at: due, deadline_at: due + Dispatch::DEADLINE, attempts: 0)
      end
      @row.update!(values)
    end
  end

  def fail!(reason, final:)
    raise Dispatch::Invalid unless @token

    @row.with_lock do
      ownership!
      attention = final || @row.attempts >= Dispatch::ATTEMPTS || @row.deadline_at <= @clock.call
      delay = [30 * (2**[@row.attempts - 1, 5].min), 900].min
      @row.update!(state: attention ? 'attention' : 'pending', result: reason, lease_token: nil, lease_expires_at: nil,
                   next_attempt_at: @clock.call + delay, next_enqueue_at: @clock.call + delay)
      @row.state
    end
  end

  def ownership!
    raise Dispatch::Invalid unless @row.state == 'running' && @row.lease_token == @token && @row.requested_fact_id == @fact_id
  end

  # The fact's event is bound to its Sync request (read when bound, recorded when not).
  # A request that only waits for renewal dispatch (a renewal_pending attention, or a
  # waiting pending one whatever its deadline) is re-armed, then enqueued exactly once.
  def enqueue_sync!
    fact = Toybaco::RenewalInvoiceFact.find(@fact_id)
    event = Toybaco::BillingEvent.find(fact.billing_event_id)
    now = @clock.call
    request = Toybaco::Growth::BillingSubscription.bind!(event, now: now)
    Toybaco::SubscriptionReconciliation.rearm_waiting!(request, now: now)
    Toybaco::SubscriptionReconciliation::Dispatch.enqueue(request, now: now)
  end
end
