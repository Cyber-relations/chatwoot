# frozen_string_literal: true

require_relative 'inbox_retention'
require_relative 'retention_snapshot'

module Toybaco::Growth::PostingStopContext
  Invalid = Class.new(Toybaco::Growth::InboxRetention::Invalid)
  Busy = Class.new(Toybaco::Growth::InboxRetention::Busy)
  HASH = /\A[0-9a-f]{64}\z/
  FIELDS = %w[account_id operation_id contract_hash target_hash].freeze

  module_function

  def digest(value)
    Toybaco::Growth::RetentionSnapshot.fingerprint(value)
  end

  def hashes?(values)
    values.all? { |value| value.is_a?(String) && HASH.match?(value) }
  end

  def validate!(record, now: Time.now.utc)
    raise Invalid unless record&.account_id&.positive?
    raise Invalid unless hashes?(record.attributes.values_at('operation_id', 'contract_hash', 'target_hash', 'request_hash'))
    raise Invalid unless record.contract_hash != record.target_hash && record.request_hash == digest(record.attributes.slice(*FIELDS))

    validate_times!(record, now)
    record
  end

  def validate_times!(record, now)
    raise Invalid unless %w[pending applied withdrawn].include?(record.state) && record.created_at <= now
    raise Invalid unless record.updated_at.between?(record.created_at, now)

    terminal = record.terminal_at
    raise Invalid unless record.state == 'pending' ? terminal.nil? : terminal&.between?(record.created_at, record.updated_at)
  end

  def fields(account_id, operation_id, request)
    raise Invalid unless account_id.is_a?(Integer) && account_id.positive? && request_shape?(request)

    result = request.merge('account_id' => account_id, 'operation_id' => operation_id)
    raise Invalid unless hashes?(result.values_at('operation_id', 'contract_hash', 'target_hash'))
    raise Invalid if result['contract_hash'] == result['target_hash']

    result
  end

  def request_shape?(request)
    request.is_a?(Hash) && request.keys.all?(String) && request.keys.sort == %w[contract_hash target_hash]
  end

  def pending(account_id)
    row = Toybaco::GrowthPostingStop.where(account_id: account_id).where.not(state: %w[applied withdrawn]).first
    validate!(row) if row
  end

  def guard_admission!(account_id)
    require_relative 'posting_renewal_fence'
    require_relative 'posting_paid_upgrade_fence'
    Toybaco::Growth::PostingRenewalFence.guard!(account_id)
    Toybaco::Growth::PostingPaidUpgradeFence.guard!(account_id)
    raise Busy if pending(account_id)
  end

  def guard_change!(account_id, before_hash, after_hash)
    row = pending(account_id)
    return unless row

    raise Invalid unless row.contract_hash == before_hash
    raise Busy unless row.target_hash == after_hash
  end

  def complete_change!(account)
    # Called inside the same Account update transaction, after the row write.
    row = pending(account.id)
    return unless row && row.target_hash == Toybaco::Growth::PostingExecutionContext.contract_hash(account)

    now = Time.now.utc
    row.update!(state: 'applied', terminal_at: now, updated_at: now)
  end
end
