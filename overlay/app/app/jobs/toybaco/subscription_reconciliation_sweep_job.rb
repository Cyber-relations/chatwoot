# frozen_string_literal: true

require_relative '../../../lib/toybaco/subscription_reconciliation'

class Toybaco::SubscriptionReconciliationSweepJob < ApplicationJob
  queue_as :scheduled_jobs
  SUSPENSION_BATCH = 100
  REQUEST = 'toybaco_subscription_sync_requests'
  STORE = 'accounts.internal_attributes'
  JOURNAL = "#{STORE} -> 'toybaco_growth_renewal_transition'".freeze
  CONTRACT = "#{STORE} -> 'toybaco_contract'".freeze
  # SubscriptionReconciliation.suspension_request?: a renewal_pending attention stays out only
  # while a dispatch row of its subscription can still re-arm it, the same rows as
  # SubscriptionReconciliation.rearming_dispatch? (no attention rows). A NULL result stays in.
  NOT_WAITING = "#{REQUEST}.result IS DISTINCT FROM 'renewal_pending' OR NOT EXISTS (SELECT 1 FROM toybaco_growth_renewal_dispatches d " \
                "JOIN toybaco_renewal_operations o ON o.id = d.renewal_operation_id WHERE o.mode = #{REQUEST}.mode AND " \
                "o.subscription_id = #{REQUEST}.subscription_id AND " \
                "(d.state IN ('pending', 'running') OR (d.state = 'idle' AND d.phase = 'grace_ready')))".freeze
  # PeriodEndCancel.return_latched?: this subscription's cancel journal that is not complete.
  LATCHED = "#{JOURNAL} ->> 'state' IN ('prepared', 'provider_closed') AND #{JOURNAL} -> 'binding' -> 'cancel' IS NOT NULL AND " \
            "#{JOURNAL} -> 'binding' ->> 'subscription_id' = #{REQUEST}.subscription_id".freeze
  # PeriodEndCancel.suspension_skipped?: its ended period-end cancellation on the paid contract of
  # the current growth terms (paid_contract?: version and meter are bound, in this order).
  SKIPPED = "#{STORE} ->> 'toybaco_subscription_status' = 'canceled' AND #{STORE} -> 'toybaco_cancel_at_period_end' = CAST('true' AS jsonb) AND " \
            "jsonb_typeof(#{CONTRACT}) = 'object' AND #{CONTRACT} ->> 'plan_id' IS DISTINCT FROM 'free' AND " \
            "#{CONTRACT} -> 'plan_version' = CAST(? AS jsonb) AND " \
            "#{CONTRACT} -> 'legacy' IS DISTINCT FROM CAST('true' AS jsonb) AND #{CONTRACT} -> 'addons' = CAST('[]' AS jsonb) AND " \
            "#{CONTRACT} -> 'entitlements' -> 'ai_meter' = CAST(? AS jsonb)".freeze

  def perform
    now = Time.now.utc
    records = Toybaco::SubscriptionSyncRequest
    records.where(state: Toybaco::SubscriptionReconciliation::STATES)
           .where('next_attempt_at <= ? AND next_enqueue_at <= ?', now, now)
           .order(:next_attempt_at, :id).limit(100).each do |record|
      Toybaco::SubscriptionReconciliation::Dispatch.enqueue(record, now: now)
    end
    suspension_candidates(now).each { |record| Toybaco::SubscriptionReconciliation::Dispatch.enqueue_suspension(record, now: now) }
    Rails.logger.error('TOYBACO_SUBSCRIPTION_SYNC_ATTENTION') if records.exists?(state: 'attention')
  end

  private

  # SubscriptionReconciliation.suspension_due? in SQL, which re-checks each one under the
  # request lock: the active store still holds the request's subscription, with either its
  # unfinished cancel journal or the Sync's mark of the skipped suspension. A request it
  # would refuse never takes a place in the batch ahead of a due one.
  def suspension_candidates(now)
    scope = Toybaco::SubscriptionSyncRequest.where(state: 'attention').where("#{REQUEST}.next_enqueue_at <= ?", now)
    scope = scope.where("(#{NOT_WAITING})")
    scope = scope.joins("JOIN accounts ON accounts.id = #{REQUEST}.account_id").where(accounts: { status: Account.statuses.fetch('active') })
    scope = scope.where("#{STORE} ->> 'toybaco_subscription_id' = #{REQUEST}.subscription_id")
    scope = scope.where("(#{LATCHED}) OR (#{SKIPPED})", Toybaco::GrowthTerms::VERSION.to_json, Toybaco::GrowthTerms::METER.to_json)
    scope.order(:next_enqueue_at, :id).limit(SUSPENSION_BATCH)
  end
end
