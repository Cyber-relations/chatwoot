# frozen_string_literal: true

# The journal keeps writers fenced after the planned contract change, until
# the current pointers in both databases are ready. Disabling flags keeps it.
module Toybaco::Growth::PostingPaidUpgradeFence
  CONTEXT = :toybaco_posting_paid_upgrade_contract_write

  module_function

  def pending(account_id)
    return unless defined?(Toybaco::GrowthPostingPaidUpgrade)

    Toybaco::GrowthPostingPaidUpgrade.where(account_id: account_id).where.not(state: %w[ready withdrawn]).first
  end

  def guard!(account_id)
    raise Toybaco::Growth::PostingExecutionContext::Busy if pending(account_id)
  end

  def guard_change!(account, previous_status, previous_attrs)
    row = pending(account.id)
    return unless row

    context = ActiveSupport::IsolatedExecutionState[CONTEXT]
    execution = Toybaco::Growth::PostingExecutionContext
    before = execution.digest(execution.binding(previous_status, previous_attrs))
    after = execution.contract_hash(account)
    raise execution::Busy unless context == [account.id, row.operation_id, before, after] && row.state == 'prepared' &&
                                 row.receipt.values_at('source_contract_hash', 'target_contract_hash') == [before, after]
  end

  def with_change(row)
    saved = ActiveSupport::IsolatedExecutionState[CONTEXT]
    ActiveSupport::IsolatedExecutionState[CONTEXT] = [row.account_id, row.operation_id,
                                                      row.receipt['source_contract_hash'], row.receipt['target_contract_hash']]
    yield
  ensure
    ActiveSupport::IsolatedExecutionState[CONTEXT] = saved
  end
end
