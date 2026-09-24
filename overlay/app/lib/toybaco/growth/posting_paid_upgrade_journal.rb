# frozen_string_literal: true

require_relative 'posting_paid_upgrade_protocol'

module Toybaco::Growth::PostingPaidUpgradeJournal
  Record = Toybaco::Growth::PostingPreparationRecord
  FIELDS = %w[version account_id operation_id owner_id source_authority_id source_authority_hash source_postiz_hash
              source_contract_hash target_contract_hash source_pointer_hash source_context target_binding handoff created_at].freeze
  CONTEXT_FIELDS = %w[principal binding contract_hash].freeze
  def validate!(row, now:)
    value = row.receipt
    validate_shape!(row, value, now)
    validate_context_hashes!(row, value)
    if %w[applied active ready].include?(row.state)
      validate_application!(row, value)
    else
      raise Record::Invalid unless [row.application, row.applied_context, row.applied_pointer_hash].all?(&:nil?)
    end
    value
  end

  def validate_shape!(row, value, now)
    raise Record::Invalid unless value.is_a?(Hash) && value.keys.sort == (FIELDS + ['receipt_hash']).sort && value['version'] == 1
    raise Record::Invalid unless value['receipt_hash'] == Record.digest(value.slice(*FIELDS)) &&
                                 value.values_at('account_id', 'operation_id') == [row.account_id, row.operation_id]

    validate_times!(row, value, now)
    raise Record::Invalid unless %w[pending prepared applied active ready withdrawn].include?(row.state)
  end

  def validate_times!(row, value, now)
    raise Record::Invalid unless row.created_at.to_i == value['created_at'] && row.created_at <= now &&
                                 row.updated_at.between?(row.created_at, now)
  end

  def validate_context_hashes!(row, value)
    names = %w[source_authority_id source_authority_hash source_postiz_hash source_contract_hash target_contract_hash source_pointer_hash]
    raise Record::Invalid unless Record.hash?(row.operation_id) && names.all? { |key| Record.hash?(value[key]) }
    raise Record::Invalid unless value['source_context'].is_a?(Hash) && value['source_context'].keys.sort == CONTEXT_FIELDS.sort

    Toybaco::Growth::PostingPaidUpgradeProtocol.validate_handoff!(value['handoff'])
    raise Record::Invalid unless value['handoff']['journalHash'] == Record.digest(value.except('handoff', 'receipt_hash'))

    validate_handoff_binding!(value)
  end

  def validate_handoff_binding!(value)
    expected = value.values_at('account_id', 'operation_id', 'source_authority_id', 'source_postiz_hash', 'source_contract_hash',
                               'target_contract_hash')
    keys = %w[accountId operationId sourceAuthorityId sourceAuthorityHash sourceBindingHash targetBindingHash]
    raise Record::Invalid unless value['handoff'].values_at(*keys) == expected &&
                                 value['handoff']['sourcePrincipalHash'] == Record.digest(value.dig('source_context', 'principal'))
  end

  def validate_application!(row, value)
    context = row.applied_context
    raise Record::Invalid unless context.is_a?(Hash) && context.keys.sort == CONTEXT_FIELDS.sort && Record.hash?(row.applied_pointer_hash)

    Toybaco::Growth::PostingPaidUpgradeProtocol.validate_application!(row.application)
    raise Record::Invalid unless context['binding'] == value['target_binding'] && context['contract_hash'] == value['target_contract_hash'] &&
                                 row.application['targetPrincipalHash'] == Record.digest(context['principal'])
  end
end
