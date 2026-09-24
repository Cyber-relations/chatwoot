# frozen_string_literal: true

require_relative 'retention_snapshot'
require_relative 'posting_stop'

module Toybaco::Growth::RenewalCoordinatorRecord
  Invalid = Class.new(StandardError)
  Changed = Class.new(Invalid)
  MODEL = Toybaco::GrowthRenewalCoordinator
  PHASES = %w[prepared waiting stop_recorded attention free_completed].freeze
  FIELDS = %w[version cause account_id renewal_operation_id operation_id due_at source target_hash
              selection_revision journal evidence_hash prepared_at].freeze

  module_function

  def digest(value) = Toybaco::Growth::RetentionSnapshot.fingerprint(value)

  def validate!(row, now:)
    value = row.receipt
    shape!(row, value)
    identity!(row, value)
    times!(row, value, now)
    journal!(row, value)
    value
  end

  def shape!(row, value)
    raise Invalid unless value.is_a?(Hash) && value.keys.sort == FIELDS.sort && value['version'] == 1 && value['cause'] == 'ordinary_renewal'

    hashes!(row, value)
  end

  def hashes!(row, value)
    raise Invalid unless row.receipt_hash == digest(value) && PHASES.include?(row.phase)
    raise Invalid unless %w[operation_id target_hash selection_revision evidence_hash].all? { |key| /\A[0-9a-f]{64}\z/.match?(value[key].to_s) }
  end

  def identity!(row, value)
    raise Invalid unless value.values_at('account_id', 'renewal_operation_id', 'operation_id', 'due_at') ==
                         [row.account_id, row.renewal_operation_id, row.operation_id, row.due_at.to_i]
    raise Invalid unless row.operation_id == operation_id(value.fetch('source'))
  end

  def times!(row, value, now)
    raise Invalid unless value['prepared_at'].is_a?(Integer) && value['prepared_at'] == row.created_at.to_i
    raise Invalid unless row.created_at <= now && row.updated_at.between?(row.created_at, now)
    raise Invalid unless value['due_at'] <= value['prepared_at']
  end

  def journal!(row, value)
    raise Invalid unless Toybaco::Growth::RenewalTransition.valid?(value['journal'])
    raise Invalid unless value['journal']['state'] == 'prepared' && value.dig('journal', 'binding', 'account_id') == row.account_id
  end

  def operation_id(source)
    digest('cause' => 'ordinary_renewal', 'version' => 1, 'failure' => source.fetch('failure'), 'contract_hash' => source.fetch('contract_hash'))
  end

  def result(row)
    { 'operation_id' => row.operation_id, 'phase' => row.phase, 'receipt_hash' => row.receipt_hash, 'execute' => false }
  end
end
