# frozen_string_literal: true

module Toybaco::Growth::PostingRenewalTarget
  Authority = Toybaco::Growth::PostingAuthorityRecord
  Renewal = Toybaco::Growth::PostingRenewalRecord
  Record = Toybaco::Growth::PostingPreparationRecord

  module_function

  def wire(renewal)
    value = receipt(renewal)
    data = renewal.receipt
    { 'accountId' => renewal.account_id, 'organizationId' => Toybaco::PostizSync.deterministic_organization_id(renewal.account_id),
      'authorityId' => renewal.target_authority_id, 'preparationRequestId' => data['preparation_request_id'],
      'preparationReceiptHash' => data['preparation_receipt_hash'], 'railsAuthorityHash' => value['receipt_hash'],
      'expiresAt' => value['expires_at'], 'scheduledPostsPerAccount' => value['scheduled_posts_per_account'],
      'expectedPointerHash' => data['expected_postiz_pointer_hash'], 'kind' => renewal.kind, 'operationId' => renewal.request_id,
      'sourceAuthorityId' => renewal.source_authority_id, 'sourceAuthorityHash' => data['source_authority_hash'],
      'handoffReceiptHash' => data['receipt_hash'], 'contractAppliedHash' => data['contract_hash'], 'targetPrincipalHash' => data['principal_hash'] }
  end

  def receipt(renewal, source: nil)
    data = renewal.receipt
    source ||= Toybaco::GrowthPostingAuthority.find_by!(account_id: renewal.account_id, authority_id: renewal.source_authority_id)
    raise Record::Invalid unless source.receipt['receipt_hash'] == data['source_rails_hash'] &&
                                 Record.digest(source.receipt.except('receipt_hash')) == data['source_rails_hash']

    validate_recovery!(data, source)
    compose_target(renewal, source.receipt.slice(*Authority::FIELDS))
  end

  def validate_recovery!(data, source)
    evidence = data.fetch('evidence')
    expected = if evidence['kind'] == 'renewal_paid' && evidence['failure']
                 evidence.slice('failure', 'period', 'coverage')
               elsif source.receipt['operation'] == 'paid_upgrade'
                 Toybaco::Growth::PostingPaidUpgradeRecord.renewal_recovery(source, now: Time.at(data['created_at']).utc)
               elsif Toybaco::Growth::PostingRenewalAuthority.typed?(source.receipt)
                 prior_recovery!(source)
               end
    raise Record::Invalid unless data['recovery'] == expected
  end

  def prior_recovery!(source)
    parent = Toybaco::GrowthPostingRenewal.find_by!(account_id: source.account_id, request_id: source.receipt['continuation_request_id'])
    value = parent.receipt
    raise Record::Invalid unless value['receipt_hash'] == source.receipt['continuation_hash'] &&
                                 Record.digest(value.except('receipt_hash')) == value['receipt_hash']

    value['recovery']
  end

  def compose_target(renewal, base)
    data = renewal.receipt
    value = base.merge(
      'version' => 2, 'authority_id' => renewal.target_authority_id, 'kind' => renewal.kind,
      'source_authority_id' => renewal.source_authority_id, 'source_authority_hash' => data['source_authority_hash'],
      'continuation_request_id' => renewal.request_id, 'continuation_hash' => data['receipt_hash'],
      'binding' => Renewal.new_binding(data), 'principal_hash' => data['principal_hash'],
      'expected_rails_pointer_hash' => data['expected_rails_pointer_hash'], 'expected_postiz_pointer_hash' => data['expected_postiz_pointer_hash'],
      'expires_at' => data.dig('evidence', 'expires_at'), 'revision' => data['receipt_hash'], 'created_at' => data['created_at']
    )
    value.merge('receipt_hash' => Record.digest(value))
  end
end
