# frozen_string_literal: true

require_relative 'posting_authority_inventory_record'
require_relative 'posting_renewal_inventory_validation'

# Read-only proof of original schedule -> current ordinary renewal. Expiry is
# intentionally checked by admission, not by inventory needed to stop a store.
class Toybaco::Growth::PostingRenewalInventory
  include Toybaco::Growth::PostingRenewalInventoryValidation

  Record = Toybaco::Growth::PostingAuthorityInventoryRecord
  Hashing = Toybaco::Growth::PostingPreparationRecord
  Invalid = Record::Invalid
  EXTRA = %w[kind operationId sourceAuthorityId sourceAuthorityHash handoffReceiptHash contractAppliedHash targetPrincipalHash].freeze
  FIELDS = %w[version protocol phase kind organizationId operationId sourceAuthorityId sourceAuthorityHash targetAuthorityId targetAuthorityHash
              handoffReceiptHash contractAppliedHash targetPrincipalHash sourcePointerHash preparationRequestId expiresAt targetAuthority
              billingEvidenceHash sourceCoverageHash targetCoverageHash sourceTermStart sourceTermEnd termStart termEnd firstFailedAt dueAt
              periodHash planRank postingAccountLimit execute].freeze
  ROOT_FIELDS = (%w[originalAuthorityId originalAuthorityHash] + Toybaco::Growth::PostingPaidUpgradeInventory::ROOT_FIELDS).freeze

  def initialize(connection, authority, fingerprint, original, **options)
    @connection = connection
    @authority = authority
    @fingerprint = fingerprint
    @original = original
    @recovery = options[:recovery]
    @pointer = options[:pointer]
    @organization = original.fetch('organizationId')
    load_record!
  end

  def context
    @request.slice('targetPrincipalHash', 'contractAppliedHash', 'postingAccountLimit')
            .transform_keys('targetPrincipalHash' => 'principalHash', 'contractAppliedHash' => 'contractHash')
  end

  def schedule?(row, value)
    return true if row['authorityId'] == @authority['authorityId'] && value['authorityHash'] == @fingerprint

    root = @receipt.fetch('roots').find { |item| item.values_at('rootId', 'rootGeneration') == row.values_at('rootId', 'rootGeneration') }
    raise Invalid unless root && root.values_at('scheduleHash', 'saveRequestId', 'postPayloadHash', 'originalAuthorityId', 'originalAuthorityHash') ==
                                 [row['scheduleHash'], value['saveRequestId'], value['postPayloadHash'], row['authorityId'], value['authorityHash']]

    edge = one('ToybacoPostingScheduleContinuation', '"rootId" = $2 AND "rootGeneration" = $3 AND "targetAuthorityId" = $4',
               [row['rootId'], row['rootGeneration'], @authority['authorityId']])
    validate_edge!(edge, root)
    validate_original!(row, value)
    true
  end

  private

  def validate_original!(row, value)
    original = one('ToybacoPostingAuthority', '"authorityId" = $2', [row['authorityId']])
    raise Invalid unless original && Hashing.digest(Record.object(original.fetch('payload'))) == original['authorityHash'] &&
                         original['authorityHash'] == value['authorityHash']
  end

  def one(table, condition, values)
    rows = @connection.exec_params("SELECT * FROM \"#{table}\" WHERE \"organizationId\" = $1 AND #{condition}", [@organization] + values).to_a
    raise Invalid unless rows.size <= 1

    rows.first
  end

  def load_record!
    raise Invalid unless @authority.keys.sort == (Toybaco::Growth::PostingAuthorityRecord::WIRE_FIELDS + EXTRA).sort &&
                         Hashing.digest(@authority) == @fingerprint && %w[renewal_grace renewal_paid].include?(@authority['kind'])

    @row = one('ToybacoPostingRenewal', '"operationId" = $2', [@authority.fetch('operationId')])
    raise Invalid unless @row && %w[applied ready].include?(@row['state'])

    @request = Record.object(@row.fetch('request'))
    @receipt = Record.object(@row.fetch('receipt'))
    validate_request!
    validate_receipt!
    validate_phase!
    validate_source!
  end

  def validate_source!
    source = one('ToybacoPostingAuthority', '"authorityId" = $2', [@request['sourceAuthorityId']])
    raise Invalid unless source && source['authorityHash'] == @request['sourceAuthorityHash']

    value = Record.object(source.fetch('payload'))
    raise Invalid unless Hashing.digest(value) == source['authorityHash'] &&
                         value.values_at('organizationId', 'authorityId') == source.values_at('organizationId', 'authorityId') &&
                         value.values_at('accountId', 'preparationRequestId', 'preparationReceiptHash', 'scheduledPostsPerAccount') ==
                         @authority.values_at('accountId', 'preparationRequestId', 'preparationReceiptHash', 'scheduledPostsPerAccount')
  end

  def validate_edge!(edge, root)
    raise Invalid unless edge

    expected = root.merge('kind' => @authority['kind'], 'organizationId' => @organization, 'operationId' => @authority['operationId'],
                          'handoffReceiptHash' => @row['receiptHash'], 'sourceAuthorityId' => root['originalAuthorityId'],
                          'sourceAuthorityHash' => root['originalAuthorityHash'], 'targetAuthorityId' => @authority['authorityId'],
                          'targetAuthorityHash' => @fingerprint)
    raise Invalid unless Record.object(edge.fetch('payload')) == expected && Hashing.digest(expected) == edge['continuationHash']
  end
end
