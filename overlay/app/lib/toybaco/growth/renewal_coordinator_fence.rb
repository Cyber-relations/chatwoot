# frozen_string_literal: true

# A stop's target hash alone is not permission to apply Free. The coordinator
# survives provider response loss and flag-off, including manual attention.
module Toybaco::Growth::RenewalCoordinatorFence
  KEY = :toybaco_renewal_coordinator_write
  SOURCE_KEYS = %w[toybaco_growth_paid_period toybaco_growth_renewal_failure toybaco_growth_retention_selection
                   toybaco_plan_change toybaco_cancel_request toybaco_billing_review toybaco_billing_payment_pending
                   toybaco_billing_suspended toybaco_subscription_status toybaco_store_purchase
                   toybaco_growth_renewal_transition toybaco_growth_renewal_settlement].freeze

  module_function

  def pending(account_id)
    return unless defined?(Toybaco::GrowthRenewalCoordinator)

    Toybaco::GrowthRenewalCoordinator.where(account_id: account_id).where.not(phase: 'free_completed').first
  end

  def guard!(account_id)
    raise Toybaco::Growth::PostingExecutionContext::Busy if pending(account_id)
  end

  def projection(status, attrs)
    execution = Toybaco::Growth::PostingExecutionContext
    execution.binding(status, attrs).merge(attrs.slice(*SOURCE_KEYS))
  end

  def guard_change!(account, status, before)
    row = pending(account.id)
    return false unless row

    old = projection(status, before)
    requested = projection(account.status, account.internal_attributes || {})
    return false if old == requested

    expected = [account.id, row.id, old, requested]
    raise Toybaco::Growth::PostingExecutionContext::Busy unless ActiveSupport::IsolatedExecutionState[KEY] == expected

    true
  end

  def with_write(parent, account, attributes, final: false)
    previous = ActiveSupport::IsolatedExecutionState[KEY]
    raise Toybaco::Growth::PostingExecutionContext::Invalid unless Account.connection.transaction_open?

    validate_write!(parent, account, attributes, final)
    ActiveSupport::IsolatedExecutionState[KEY] = [account.id, parent.id, projection(account.status, account.internal_attributes),
                                                  projection('active', attributes)]
    yield
  ensure
    ActiveSupport::IsolatedExecutionState[KEY] = previous
  end

  def validate_write!(parent, account, attributes, final)
    if final
      require_relative 'renewal_coordinator_settlement_record'
      row = Toybaco::GrowthRenewalSettlement.find_by!(coordinator_id: parent.id)
      Toybaco::Growth::RenewalCoordinatorSettlementRecord.validate!(row, parent, now: Time.now.utc)
      raise Toybaco::Growth::PostingExecutionContext::Invalid unless row.phase == 'provider_closed'
    else
      allowed = %w[toybaco_growth_renewal_transition toybaco_growth_renewal_settlement]
      raise Toybaco::Growth::PostingExecutionContext::Invalid unless attributes.except(*allowed) == account.internal_attributes.except(*allowed)
    end
  end
end
