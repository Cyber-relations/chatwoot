# frozen_string_literal: true

module Toybaco::Growth::PostingRenewalProtocol
  require_relative 'posting_paid_upgrade_terms'

  Record = Toybaco::Growth::PostingPreparationRecord
  RenewalAuthority = Toybaco::Growth::PostingRenewalAuthority
  VERIFIED_PROTOCOL = 'toybaco-posting-renewal-v1'
  RESPONSE_FIELDS = %w[version protocol requestHash operationId sourceAuthorityId targetAuthorityId targetAuthorityHash
                       sourcePointerHash targetPointerHash receiptHash rootManifestHash state execute].freeze

  def self.validate_receipt!(response, payload)
    raise Record::Invalid unless response.is_a?(Hash) && response.keys.sort == RESPONSE_FIELDS.sort

    fields = %w[version protocol operationId sourceAuthorityId targetAuthorityId targetAuthorityHash sourcePointerHash execute]
    state = payload['phase'] == 'confirm' ? 'ready' : 'prepared'
    raise Record::Invalid unless response.slice(*fields) == payload.slice(*fields) && response['state'] == state &&
                                 response['requestHash'] == Record.digest(payload)

    validate_response_hashes!(response)
  end

  def self.validate_response_hashes!(response)
    raise Record::Invalid unless %w[targetPointerHash receiptHash rootManifestHash].all? { |key| Record.hash?(response[key]) }
  end

  private

  def exchange!(row, phase)
    payload = exchange_payload(row, phase)
    response = @transport.call(payload.deep_dup).deep_dup
    @now = @clock.call
    Toybaco::Growth::PostingRenewalProtocol.validate_receipt!(response, payload)
    response
  end

  def exchange_payload(row, phase)
    target = RenewalAuthority.target_wire(row)
    { 'version' => 1, 'protocol' => VERIFIED_PROTOCOL, 'phase' => phase, 'kind' => target['kind'],
      'organizationId' => target['organizationId'],
      'operationId' => row.request_id, 'sourceAuthorityId' => row.source_authority_id,
      'sourceAuthorityHash' => row.receipt['source_authority_hash'], 'targetAuthorityId' => row.target_authority_id,
      'targetAuthorityHash' => Record.digest(target), 'handoffReceiptHash' => row.receipt['receipt_hash'],
      'contractAppliedHash' => row.receipt['contract_hash'], 'targetPrincipalHash' => row.receipt['principal_hash'],
      'sourcePointerHash' => row.receipt['expected_postiz_pointer_hash'],
      'preparationRequestId' => row.receipt['preparation_request_id'], 'expiresAt' => target['expiresAt'],
      'targetAuthority' => target,
      'billingEvidenceHash' => Record.digest(row.receipt.fetch('evidence')), 'execute' => false }.merge(term_payload(row))
  end

  def term_payload(row)
    evidence = row.receipt.fetch('evidence')
    previous, period, coverage = evidence.values_at('previous_coverage', 'period', 'coverage')
    contract = evidence.dig('binding', 'contract')
    terms = Toybaco::Growth::PostingPaidUpgradeTerms
    { 'sourceCoverageHash' => Record.digest(previous), 'targetCoverageHash' => coverage && Record.digest(coverage),
      'sourceTermStart' => previous.fetch('term_start'), 'sourceTermEnd' => previous.fetch('term_end'),
      'termStart' => period.fetch('term_start'), 'termEnd' => period.fetch('term_end'),
      'firstFailedAt' => evidence.dig('failure', 'first_failed_at'), 'dueAt' => evidence.dig('failure', 'due_at'),
      'periodHash' => Record.digest((coverage || period.merge('anchor' => previous.fetch('anchor'))).slice('term_start', 'term_end', 'anchor')),
      'planRank' => terms.rank(contract), 'postingAccountLimit' => terms.limits(contract).first }
  end

  def recovery_inventory_scope(row, target_pointer)
    request = exchange_payload(row, 'prepare')
    request.slice('operationId', 'sourceAuthorityId', 'sourceAuthorityHash', 'targetAuthorityId', 'targetAuthorityHash', 'handoffReceiptHash')
           .merge('targetPointerHash' => target_pointer)
  end

  module_function :exchange_payload, :term_payload

  def target_ack(row, response)
    { 'authorityId' => row.target_authority_id, 'authorityHash' => response['targetAuthorityHash'],
      'state' => response['state'] == 'ready' ? 'ready' : 'pending', 'current' => true, 'execute' => false,
      'pointerHash' => response['targetPointerHash'] }
  end
end
