# frozen_string_literal: true

require_relative 'inbox_retention'
require_relative 'inbox_upgrade_continuation'
require_relative 'posting_execution_context'

# Account writers already have different outer locks/transactions. Take a
# nonblocking transaction fence before the UPDATE, never a waiting inverse
# lock. A contract restored later does not restore an earlier release.
module Toybaco::Growth::InboxContractBoundary
  HOLD = Toybaco::Growth::InboxRetention
  EPOCH = Toybaco::Growth::InboxDeliveryEpoch
  RELEASE = Toybaco::Growth::InboxReleaseRecord
  PROTECTED = [HOLD::KEY, EPOCH::KEY, RELEASE::KEY].freeze
  BINDING = %w[toybaco_contract toybaco_subscription_id toybaco_stripe_customer_id].freeze
  CONTEXT = :toybaco_inbox_release_write

  module_function

  def apply!(account)
    Account.uncached do
      previous = current_row!(account)
      attrs = account.internal_attributes || {}
      old = previous.last || {}
      Toybaco::Growth::PostingExecutionContext.guard_change!(account, previous.first, old)
      update_authority!(account, previous.first, old, attrs) if protected?(old, attrs)
    end
  rescue ActiveRecord::LockWaitTimeout
    raise HOLD::Busy
  end

  def destroy!(account)
    Account.uncached do
      current_row!(account)
      Toybaco::Growth::PostingExecutionContext.guard_pending!(account.id)
      Toybaco::Growth::PostingStopContext.guard_admission!(account.id)
      Toybaco::Growth::PostingPrincipal.rotate!(account.id)
    end
  rescue ActiveRecord::LockWaitTimeout
    raise HOLD::Busy
  end

  def protected?(before, after)
    before.slice(*PROTECTED).any? || after.slice(*PROTECTED).any?
  end

  def update_authority!(account, old_status, before, after)
    validate_baseline!(account, before)
    changed = authority_changed?(old_status, account.status, before, after)
    lock!(account.id) if changed || before.slice(*PROTECTED) != after.slice(*PROTECTED)
    validate_requested!(account.id, before, after)
    revoke!(account, before, after, old_status) if before[HOLD::KEY] && changed
  end

  def current_row!(account)
    connection = Account.connection
    raise HOLD::Invalid unless connection.transaction_open?

    row = Account.where(id: account.id).lock('FOR UPDATE NOWAIT').pick(:status, :internal_attributes)
    raise HOLD::Invalid unless row && (row.last.nil? || row.last.is_a?(Hash)) &&
                               (account.internal_attributes.nil? || account.internal_attributes.is_a?(Hash))

    row
  end

  def lock!(account_id)
    connection = Account.connection
    raise HOLD::Invalid unless connection.select_value('SHOW transaction_isolation') == 'read committed'
    raise HOLD::Busy unless connection.select_value("SELECT pg_try_advisory_xact_lock(#{HOLD.fence_key(account_id)})")
  end

  def validate_baseline!(account, current)
    baseline = account.attribute_in_database('internal_attributes') || {}
    # A stale whole-JSON write must not restore a pointer/epoch removed by
    # another transaction. Normal callers retry from a fresh account.
    raise HOLD::Invalid unless baseline.is_a?(Hash) && baseline.slice(*PROTECTED) == current.slice(*PROTECTED)
  end

  def with_release(account_id, pointer)
    previous = ActiveSupport::IsolatedExecutionState[CONTEXT]
    ActiveSupport::IsolatedExecutionState[CONTEXT] = [account_id, pointer]
    yield
  ensure
    ActiveSupport::IsolatedExecutionState[CONTEXT] = previous
  end

  def validate_requested!(account_id, before, after)
    return unless before[HOLD::KEY] && after[HOLD::KEY] == before[HOLD::KEY]

    raise HOLD::Invalid unless before[EPOCH::KEY] == after[EPOCH::KEY]
    return if before[RELEASE::KEY] == after[RELEASE::KEY] || !after.key?(RELEASE::KEY)

    raise HOLD::Invalid unless ActiveSupport::IsolatedExecutionState[CONTEXT] == [account_id, after[RELEASE::KEY]]
  end

  def authority_changed?(old_status, status, before, after)
    # past_due/payment-pending alone does not remove existing rights during
    # the renewal grace period. The verified stop or binding change does.
    binding(before) != binding(after) || (old_status == 'active' && status != 'active')
  end

  def binding(attrs)
    purchase = attrs['toybaco_growth_purchase']
    values = attrs.slice(*BINDING)
    values['purchase'] = purchase.is_a?(Hash) ? purchase.slice('nonce', 'state', 'subscription_id', 'livemode') : purchase
    values
  end

  def revoke!(account, before, after, old_status)
    hold = before.fetch(HOLD::KEY)
    # A new stop is an independently verified installation with its own epoch.
    return if after[HOLD::KEY] != hold

    return if Toybaco::Growth::InboxUpgradeContinuation.continue!(account, before, after, old_status)

    return unless release_or_suspension?(before, after, old_status, account.status)

    now = Time.now.utc
    HOLD.validate!(hold, account_id: account.id, now: now)
    previous = EPOCH.current(account.id, before, hold, now: now)
    released = RELEASE.current(account.id, before, hold, now: now)
    ids = revoked_ids(account, old_status, released, hold)
    epochs = EPOCH.rotate(account.id, previous, ids, now, binding(after))
    # Keep the immutable release row as replay history. Only a fresh explicit
    # action can create a new current pointer after this committed revocation.
    account.internal_attributes = after.except(RELEASE::KEY).merge(EPOCH::KEY => epochs)
  rescue RELEASE::Invalid
    raise HOLD::Invalid
  end

  def release_or_suspension?(before, after, old_status, status)
    before.key?(RELEASE::KEY) || after.key?(RELEASE::KEY) || (old_status == 'active' && status != 'active')
  end

  def revoked_ids(account, old_status, released, hold)
    return EPOCH.current_ids(account) if old_status == 'active' && account.status != 'active'

    (released&.fetch('keep_inbox_ids') || []) - hold.fetch('keep_inbox_ids')
  end
end

module Toybaco::Growth::InboxContractBoundary::AccountUpdates
  extend ActiveSupport::Concern

  included do
    before_update :toybaco_inbox_contract_boundary, prepend: true
    before_destroy :toybaco_posting_execution_destroy, prepend: true
    after_update :toybaco_posting_stop_complete
  end

  private

  def toybaco_posting_stop_complete
    return unless saved_change_to_internal_attributes? || saved_change_to_status?

    Account.uncached { Toybaco::Growth::PostingStopContext.complete_change!(self) }
  end

  def toybaco_posting_execution_destroy
    Toybaco::Growth::InboxContractBoundary.destroy!(self)
  end

  def toybaco_inbox_contract_boundary
    return unless will_save_change_to_internal_attributes? || will_save_change_to_status?

    Toybaco::Growth::InboxContractBoundary.apply!(self)
  end
end
