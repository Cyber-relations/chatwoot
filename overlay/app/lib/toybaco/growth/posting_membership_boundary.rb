# frozen_string_literal: true

require_relative 'posting_execution_context'

# Membership writers and JIT/reconciliation share the Account row fence with
# execution admission. Nonblocking locks avoid reversing an outer writer lock.
module Toybaco::Growth::PostingMembershipBoundary
  EXECUTION = Toybaco::Growth::PostingExecutionContext
  STOP = Toybaco::Growth::PostingStopContext
  MEMBERSHIP_FIELDS = %w[account_id user_id role custom_role_id].freeze
  USER_FIELDS = %w[type provider uid email].freeze

  module_function

  def membership!(record, removing: false)
    guarded do
      before = membership_before!(record)
      lock_users!([before['user_id'], record.user_id], allow_missing: removing)
      ids = [before['account_id'], record.account_id].compact.uniq.sort
      lock_accounts!(ids, stopping: true, allow_missing: removing)
      ids.each { |id| Toybaco::Growth::PostingPrincipal.rotate!(id, user_ids: [before['user_id'], record.user_id].compact) }
    end
  end

  def membership_before!(record)
    return {} if record.new_record?

    current = AccountUser.where(id: record.id).lock('FOR UPDATE NOWAIT').pick(*MEMBERSHIP_FIELDS)
    raise EXECUTION::Invalid unless current

    before = MEMBERSHIP_FIELDS.zip(current).to_h
    raise EXECUTION::Invalid unless before == record.attributes_in_database.reverse_merge(record.attributes).slice(*MEMBERSHIP_FIELDS)

    before
  end

  def user!(record)
    guarded do
      lock_users!([record.id])
      ids = AccountUser.where(user_id: record.id).distinct.pluck(:account_id).sort
      lock_accounts!(ids, stopping: true)
      ids.each { |id| Toybaco::Growth::PostingPrincipal.rotate!(id, user_ids: [record.id]) }
    end
  end

  # Called inside the existing identity transaction before touching Postiz.
  # A pending planned contract stop may legitimately disable the account;
  # unfinished provider executions must still prevent every such mutation.
  def synchronize!(user_id:, account_ids:, revoking: false)
    guarded do
      lock_users!([user_id], allow_missing: account_ids.any?) if user_id
      ids = account_ids
      ids = AccountUser.where(user_id: user_id).distinct.pluck(:account_id) if user_id && ids.empty?
      lock_accounts!(ids, stopping: false)
      ids.each { |id| Toybaco::Growth::PostingPrincipal.rotate!(id, user_ids: user_id ? [user_id] : nil) } if revoking
    end
  end

  def guarded
    Account.uncached do
      connection = Account.connection
      raise EXECUTION::Invalid unless connection.transaction_open? && connection.select_value('SHOW transaction_isolation') == 'read committed'

      yield
    end
  rescue ActiveRecord::LockWaitTimeout
    raise EXECUTION::Busy
  end

  def lock_users!(ids, allow_missing: false)
    ids.compact.uniq.sort.each do |id|
      found = User.unscoped.where(id: id).lock('FOR UPDATE NOWAIT').pick(:id)
      raise EXECUTION::Invalid unless found || allow_missing
    end
  end

  def lock_accounts!(ids, stopping:, allow_missing: true)
    ids.compact.uniq.sort.each do |id|
      # Parent deletion uses destroy_async for membership cleanup. A missing
      # account cannot admit an execution, but its retained ledger is checked.
      found = Account.where(id: id).lock('FOR UPDATE NOWAIT').pick(:id)
      raise EXECUTION::Invalid unless found || allow_missing

      EXECUTION.guard_pending!(id)
      STOP.guard_admission!(id) if stopping
    end
  end

  module MembershipWrites
    extend ActiveSupport::Concern

    included do
      before_create :toybaco_posting_membership_write, prepend: true
      before_update :toybaco_posting_membership_write, prepend: true, if: :toybaco_posting_membership_changed?
      before_destroy :toybaco_posting_membership_destroy, prepend: true
    end

    private

    def toybaco_posting_membership_changed?
      changes_to_save.keys.intersect?(MEMBERSHIP_FIELDS)
    end

    def toybaco_posting_membership_write
      Toybaco::Growth::PostingMembershipBoundary.membership!(self)
    end

    def toybaco_posting_membership_destroy
      Toybaco::Growth::PostingMembershipBoundary.membership!(self, removing: true)
    end
  end

  module UserWrites
    extend ActiveSupport::Concern

    included do
      before_update :toybaco_posting_user_write, prepend: true, if: :toybaco_posting_user_changed?
      before_destroy :toybaco_posting_user_write, prepend: true
    end

    private

    def toybaco_posting_user_changed?
      changes_to_save.keys.intersect?(USER_FIELDS)
    end

    def toybaco_posting_user_write
      Toybaco::Growth::PostingMembershipBoundary.user!(self)
    end
  end
end
