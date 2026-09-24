# frozen_string_literal: true

require_relative 'posting_preparation_record'

# A transport payload for non-executable preparation, never current authority.
module Toybaco::Growth::PostingPreparationExport
  Record = Toybaco::Growth::PostingPreparationRecord
  RECORD_FIELDS = { 'request_id' => 'requestId', 'owner_id' => 'ownerId', 'receipt_hash' => 'railsReceiptHash',
                    'contract_hash' => 'contractHash', 'revision' => 'selectionRevision',
                    'requested_ids' => 'requestedIntegrationIds', 'keep_ids' => 'keepIntegrationIds' }.freeze
  POSTING_FIELDS = { 'organization_id' => 'organizationId', 'transition_id' => 'holdTransitionId',
                     'receipt_hash' => 'holdReceiptHash', 'generation' => 'holdGeneration',
                     'inventory_hash' => 'inventoryHash', 'identity_hash' => 'identityHash' }.freeze

  module_function

  def request(value, account_id, now:)
    Record.validate!(value, account_id, now: now)
    raise Record::Invalid unless [account_id, value['owner_id']].all? { |id| id.is_a?(Integer) && id.between?(1, (2**53) - 1) }

    posting = value.fetch('posting')
    result = { 'version' => 2, 'accountId' => account_id, 'actorId' => value.fetch('owner_id'),
               'ownerMembershipId' => posting.fetch('owner').fetch('membership_id'),
               'principalHash' => Record.digest(value.fetch('principal')), 'postingAccountLimit' => Record.limit(value.fetch('binding')) }
    result.merge(extract(value, RECORD_FIELDS)).merge(extract(posting, POSTING_FIELDS))
  end

  def extract(value, fields)
    fields.to_h { |source, target| [target, value.fetch(source)] }
  end
end
