# frozen_string_literal: true

require_relative 'renewal_coordinator_record'

module Toybaco::Growth::RenewalCoordinatorSettlementRecord
  Parent = Toybaco::Growth::RenewalCoordinatorRecord
  Invalid = Parent::Invalid
  MODEL = Toybaco::GrowthRenewalSettlement
  PHASES = %w[prepared invoice_voided provider_closed payment_review free_completed].freeze
  FIELDS = %w[version account_id coordinator_id coordinator_hash operation_id stop_request_hash prepared_at].freeze

  module_function

  def validate!(row, parent, now:)
    value = row.receipt
    Parent.validate!(parent, now: now)
    raise Invalid unless value.is_a?(Hash) && value.keys.sort == FIELDS.sort && value['version'] == 1
    raise Invalid unless PHASES.include?(row.phase) && row.receipt_hash == Parent.digest(value)

    identity!(row, parent, value)
    times!(row, now)

    value
  end

  def identity!(row, parent, value)
    raise Invalid unless value.values_at('account_id', 'coordinator_id', 'coordinator_hash', 'operation_id', 'prepared_at') ==
                         [row.account_id, parent.id, parent.receipt_hash, parent.operation_id, row.created_at.to_i]
    raise Invalid unless row.coordinator_id == parent.id && row.account_id == parent.account_id && row.operation_id == parent.operation_id
    raise Invalid unless /\A[0-9a-f]{64}\z/.match?(value['stop_request_hash'].to_s)
  end

  def times!(row, now)
    raise Invalid unless row.created_at <= now && row.updated_at.between?(row.created_at, now)
  end

  def result(row)
    { 'operation_id' => row.operation_id, 'phase' => row.phase, 'receipt_hash' => row.receipt_hash, 'execute' => false }
  end
end
