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

    record = Toybaco::SubscriptionSyncRequest.create_or_find_by!(subscription_id: subscription_id, mode: mode) do |row|
      ids = accounts_for(subscription_id).limit(2).pluck(:id)
      raise Invalid if ids.size > 1

      row.account_id = ids.first
      row.deadline_at = now + DEADLINE
      row.next_attempt_at = row.next_enqueue_at = now
    end
    record.with_lock { refresh_request!(record, now) } unless record.previously_new_record?
    Dispatch.enqueue(record, now: now)
    record.reload
  end

  def refresh_request!(record, now)
    # A duplicate notification must not reset an outstanding retry budget.
    return if record.state == 'attention'

    values = { requested_revision: record.requested_revision + 1 }
    unless STATES.include?(record.state)
      values.merge!(state: 'pending', attempts: 0, deadline_at: now + DEADLINE,
                    next_attempt_at: now, next_enqueue_at: now, completed_at: nil, result: nil)
    end
    record.update!(values)
  end

  def accounts_for(subscription_id)
    Account.where("internal_attributes ->> 'toybaco_subscription_id' = ?", subscription_id).order(:id)
  end

  def due?(record, now)
    STATES.include?(record.state) && record.next_attempt_at <= now
  end
end

require_relative 'subscription_reconciliation/dispatch'
