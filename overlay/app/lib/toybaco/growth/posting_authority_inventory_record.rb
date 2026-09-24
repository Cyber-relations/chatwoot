# frozen_string_literal: true

require_relative 'posting_preparation_response'

module Toybaco::Growth::PostingAuthorityInventoryRecord
  Record = Toybaco::Growth::PostingPreparationRecord
  Invalid = Toybaco::Growth::RetentionPlan::Invalid
  CONTEXT_FIELDS = %w[ownerId actorId principalHash contractHash].freeze
  REQUEST_FIELDS = (%w[version accountId actorId ownerMembershipId principalHash postingAccountLimit] +
                    Toybaco::Growth::PostingPreparationExport::RECORD_FIELDS.values +
                    Toybaco::Growth::PostingPreparationExport::POSTING_FIELDS.values).sort.freeze
  HASH_FIELDS = %w[requestId principalHash railsReceiptHash contractHash selectionRevision holdTransitionId
                   holdReceiptHash inventoryHash identityHash].freeze
  UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  module_function

  def context!(value)
    raise Invalid unless value.is_a?(Hash) && value.keys.sort == CONTEXT_FIELDS.sort &&
                         positive?(value['ownerId']) && value['actorId'] == value['ownerId'] &&
                         %w[principalHash contractHash].all? { |key| Record.hash?(value[key]) }

    value.deep_dup
  end

  def pointer!(row, organization)
    raise Invalid unless row['organizationId'] == organization && Record.hash?(row['authorityId']) &&
                         UUID.match?(row['epoch'].to_s) && /\A[1-9][0-9]{0,18}\z/.match?(row['generation'].to_s) &&
                         row['generation'].to_i < 9_223_372_036_854_775_807 && %w[pending ready stale].include?(row['state'])
  end

  def object(value)
    parsed = JSON.parse(value, allow_duplicate_key: false, max_nesting: 16)
    raise Invalid unless parsed.is_a?(Hash)

    parsed
  end

  def authority!(row, pointer)
    value = object(row.fetch('payload'))
    raise Invalid unless row.values_at('organizationId', 'authorityId') == pointer.values_at('organizationId', 'authorityId') &&
                         value.values_at('organizationId', 'authorityId') == row.values_at('organizationId', 'authorityId') &&
                         Record.digest(value) == row['authorityHash'] && Record.hash?(value['preparationRequestId']) &&
                         Record.hash?(value['preparationReceiptHash'])

    value
  end

  def preparation!(row, authority, account_id, now:)
    request = object(row.fetch('request'))
    receipt = object(row.fetch('receipt'))
    request!(request, account_id)
    Toybaco::Growth::PostingPreparationResponse.validate_receipt!(receipt, request, now: now)
    validate_preparation_row!(row, request, receipt, authority, now)
    request
  rescue Record::Invalid
    raise Invalid
  end

  def validate_preparation_row!(row, request, receipt, authority, now)
    raise Invalid unless row.values_at('organizationId', 'requestId', 'payloadHash', 'receiptHash') ==
                         receipt.values_at('organizationId', 'requestId', 'payloadHash', 'receiptHash') &&
                         request.values_at('organizationId', 'requestId') == authority.values_at('organizationId', 'preparationRequestId') &&
                         row['receiptHash'] == authority['preparationReceiptHash'] && receipt['preparedAt'] <= (now.to_r * 1000).to_i &&
                         (DateTime.parse(row.fetch('createdAt')).to_time.to_r * 1000).floor == receipt['preparedAt']
  end

  def request!(value, account_id)
    raise Invalid unless value.keys.sort == REQUEST_FIELDS && value.values_at('version', 'accountId') == [2, account_id] &&
                         positive?(account_id) && HASH_FIELDS.all? { |key| Record.hash?(value[key]) }

    validate_request_identity!(value, account_id)
    validate_selection!(value)
    raise Invalid unless JSON.generate(value).bytesize <= 65_536
  end

  def validate_request_identity!(value, account_id)
    raise Invalid unless positive?(value['ownerId']) && value['actorId'] == value['ownerId'] &&
                         value['organizationId'] == Toybaco::PostizSync.deterministic_organization_id(account_id) &&
                         Record.ids?([value['ownerMembershipId']])
  end

  def validate_selection!(value)
    requested, keep = value.values_at('requestedIntegrationIds', 'keepIntegrationIds')
    validate_limits!(value)
    raise Invalid unless [requested, keep].all? { |ids| Record.ids?(ids) } && requested.any? &&
                         keep.size <= value['postingAccountLimit'] && (requested - keep).empty?
  end

  def validate_limits!(value)
    raise Invalid unless %w[holdGeneration postingAccountLimit].all? { |key| value[key].is_a?(Integer) && value[key].between?(1, 10_000) }
  end

  def positive?(value)
    value.is_a?(Integer) && value.between?(1, 9_007_199_254_740_991)
  end
end
