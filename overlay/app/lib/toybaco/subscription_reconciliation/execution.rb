# frozen_string_literal: true

require 'digest'
require_relative '../subscription_reconciliation'
require_relative '../store_fulfillment'
require_relative '../growth/inbox_retention'
require_relative 'processing'

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

  def run
    return @record.reload.state unless claim!

    result = reconcile
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
        @record.update!(state: 'attention', result: 'retry_limit')
        next false
      end

      @revision = @record.requested_revision
      @record.update!(state: 'running', attempts: @record.attempts + 1, next_attempt_at: now + 60)
      true
    end
  end

  def retry_later!(reason)
    finish!('pending', reason)
  end

  def finish!(state, result)
    @record.with_lock do
      raise Toybaco::SubscriptionReconciliation::Invalid unless @record.state == 'running' && @revision

      values = completion_values(state, result)
      @record.update!(values)
      Rails.logger.error('TOYBACO_SUBSCRIPTION_SYNC_ATTENTION') if values[:state] == 'attention'
      @record.state
    end
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
    values[:state] = 'attention' if @record.attempts >= Toybaco::SubscriptionReconciliation::ATTEMPTS || @record.deadline_at <= now
    delay = %w[applied payment_pending superseded].include?(result) ? 0 : [30 * (2**[@record.attempts - 1, 5].min), 900].min
    values[:next_attempt_at] = now + delay
    values[:next_enqueue_at] = now + delay
  end
end
