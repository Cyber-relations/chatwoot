# frozen_string_literal: true

require_relative 'posting_paid_upgrade_protocol'
require_relative 'inbox_upgrade_record'
require_relative 'posting_paid_upgrade_journal'
require_relative 'posting_paid_renewal_link'

module Toybaco::Growth::PostingPaidUpgradeRecord
  Record = Toybaco::Growth::PostingPreparationRecord
  FIELDS = %w[version account_id operation_id owner_id source_authority_id source_authority_hash source_postiz_hash
              source_contract_hash target_contract_hash source_pointer_hash source_context target_binding handoff created_at].freeze
  EXTRA = %w[operation source_authority_id source_authority_hash source_postiz_hash journal_hash target_context
             handoff_receipt_hash contract_applied_hash].freeze
  CONTEXT_FIELDS = %w[principal binding contract_hash].freeze

  extend Toybaco::Growth::PostingPaidUpgradeJournal
  extend Toybaco::Growth::PostingPaidRenewalLink

  module_function

  def authority!(row, now:)
    value = row.receipt
    raise Record::Invalid unless value['version'] == 2 && value['operation'] == 'paid_upgrade'

    journal = Toybaco::GrowthPostingPaidUpgrade.find_by!(account_id: row.account_id, operation_id: value['revision'])
    proof = validate!(journal, now: now)
    raise Record::Invalid unless %w[applied active ready].include?(journal.state) &&
                                 value.values_at('journal_hash', 'source_authority_id', 'source_authority_hash', 'source_postiz_hash') ==
                                 proof.values_at('receipt_hash', 'source_authority_id', 'source_authority_hash', 'source_postiz_hash') &&
                                 value['target_context'] == journal.applied_context &&
                                 journal.application.values_at('authorityId', 'railsAuthorityHash', 'receiptHash', 'contractAppliedHash') ==
                                 value.values_at('authority_id', 'receipt_hash', 'handoff_receipt_hash', 'contract_applied_hash')

    validate_chain!(row, now: now)
    journal
  end

  def validate_chain!(row, now:)
    seen = []
    current = row
    while paid?(current.receipt)
      raise Record::Invalid if seen.size >= 2 || seen.include?(current.authority_id)

      seen << current.authority_id
      previous = Toybaco::GrowthPostingAuthority.find_by!(account_id: row.account_id, authority_id: current.receipt['source_authority_id'])
      validate_parent!(previous, current, now)
      current = previous
    end
    validate_anchor!(current, now: now)
    current
  end

  def validate_parent!(previous, current, now)
    return validate_renewal_parent!(previous, current, now) if renewal_paid?(previous.receipt)

    authority = Toybaco::Growth::PostingAuthorityRecord
    authority.validate_binding!(previous, previous.receipt)
    authority.validate_hashes!(previous.receipt)
    authority.validate_times!(previous, previous.receipt, now)
    validate_parent_link!(previous, current, now)
    return unless paid?(previous.receipt)

    validate!(Toybaco::GrowthPostingPaidUpgrade.find_by!(account_id: previous.account_id,
                                                         operation_id: previous.receipt['revision']), now: now)
  end

  def validate_parent_link!(previous, current, now)
    value = current.receipt
    raise Record::Invalid unless previous.receipt['receipt_hash'] == value['source_authority_hash'] &&
                                 previous.postiz_receipt&.fetch('authorityHash') == value['source_postiz_hash']
    raise Record::Invalid unless previous.preparation_request_id == current.preparation_request_id &&
                                 previous.receipt.values_at('owner_id', 'expires_at') == value.values_at('owner_id', 'expires_at')
    raise Record::Invalid unless previous.receipt['scheduled_posts_per_account'] <= value['scheduled_posts_per_account']

    validate_parent_times!(previous, current, now)
  end

  def validate_parent_times!(previous, current, now)
    raise Record::Invalid unless current.created_at.between?(previous.created_at, now)
  end

  def effective(row, prepared, now:)
    return prepared unless paid?(row.receipt)

    authority!(row, now: now)
    value = prepared.merge(row.receipt.fetch('target_context'))
    recovery = renewal_recovery(row, now: now)
    recovery ? value.merge('posting_paid_recovery' => recovery) : value
  end

  def wire_extra(row)
    value = row.receipt
    { 'kind' => 'paid_upgrade', 'operationId' => value['revision'], 'sourceAuthorityId' => value['source_authority_id'],
      'sourceAuthorityHash' => value['source_postiz_hash'], 'handoffReceiptHash' => value['handoff_receipt_hash'],
      'contractAppliedHash' => value['contract_applied_hash'], 'targetPrincipalHash' => Record.digest(value.dig('target_context', 'principal')) }
  end

  def same_execution_group?(execution, previous, now:)
    group = Toybaco::Growth::PostingExecutionV3::GROUP
    return true if previous.slice(*group) == execution.slice(*group)

    stable = group - %w[authorityId authorityHash railsAuthorityHash]
    previous.slice(*stable) == execution.slice(*stable) && follows_execution?(execution, previous, now: now)
  end

  def follows_execution?(execution, previous, now:)
    return false unless execution['step'] == 'COMMENT'

    current = Toybaco::Growth::PostingAuthorityRecord.find(execution['accountId'], execution['authorityId'], now: now)
    2.times do
      return renewal_execution?(current, execution, previous, now) if current && renewal_paid?(current.receipt)
      return false unless current && paid?(current.receipt)

      authority!(current, now: now)
      value = current.receipt
      return true if previous.values_at('authorityId', 'authorityHash', 'railsAuthorityHash') ==
                     value.values_at('source_authority_id', 'source_postiz_hash', 'source_authority_hash')

      current = Toybaco::Growth::PostingAuthorityRecord.find(execution['accountId'], value['source_authority_id'], now: now)
    end
    renewal_execution?(current, execution, previous, now)
  end
end
