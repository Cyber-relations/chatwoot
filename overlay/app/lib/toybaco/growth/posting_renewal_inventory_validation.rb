# frozen_string_literal: true

module Toybaco::Growth::PostingRenewalInventoryValidation
  Record = Toybaco::Growth::PostingAuthorityInventoryRecord
  Hashing = Toybaco::Growth::PostingPreparationRecord
  Invalid = Record::Invalid

  private

  def validate_phase!
    return if @row['state'] == 'ready' && @recovery.nil?

    fields = %w[operationId sourceAuthorityId sourceAuthorityHash targetAuthorityId targetAuthorityHash handoffReceiptHash]
    expected = @request.slice(*fields).merge('targetPointerHash' => @receipt['targetPointerHash'])
    validate_recovery!(expected)
  end

  def validate_recovery!(expected)
    raise Invalid unless @recovery == expected && @pointer

    raise Invalid unless @pointer['authorityId'] == @authority['authorityId'] &&
                         @pointer['state'] == (@row['state'] == 'applied' ? 'pending' : 'ready') &&
                         Hashing.digest(@pointer.slice('organizationId', 'authorityId', 'generation', 'epoch')) == @receipt['targetPointerHash']
  end

  def validate_request!
    raise Invalid unless @request.keys.sort == Toybaco::Growth::PostingRenewalInventory::FIELDS.sort && @request.values_at('version', 'protocol',
                                                                                                                           'phase', 'execute') ==
                                                                                                        [1, 'toybaco-posting-renewal-v1', 'prepare',
                                                                                                         false]
    raise Invalid unless @request['targetAuthority'] == @authority && @request['targetAuthorityHash'] == @fingerprint &&
                         @row.values_at('organizationId', 'operationId', 'requestHash') ==
                         [@organization, @authority['operationId'], Hashing.digest(@request.except('phase'))]
    raise Invalid unless @request.values_at('kind', 'targetAuthorityId', 'preparationRequestId', 'expiresAt', 'handoffReceiptHash',
                                            'contractAppliedHash', 'targetPrincipalHash', 'sourceAuthorityId', 'sourceAuthorityHash') ==
                         @authority.values_at('kind', 'authorityId', 'preparationRequestId', 'expiresAt', 'handoffReceiptHash',
                                              'contractAppliedHash', 'targetPrincipalHash', 'sourceAuthorityId', 'sourceAuthorityHash')

    validate_terms!
  end

  def validate_terms!
    raise Invalid unless %w[sourceTermStart sourceTermEnd termStart termEnd expiresAt].all? { |key| Record.positive?(@request[key]) } &&
                         @request['sourceTermStart'] < @request['sourceTermEnd'] && @request['sourceTermEnd'] == @request['termStart'] &&
                         @request['termStart'] < @request['termEnd']

    validate_limits!
    validate_expiry!
  end

  def validate_limits!
    raise Invalid unless @request['planRank'].is_a?(Integer) && @request['planRank'].between?(1, 3) &&
                         @request['postingAccountLimit'].is_a?(Integer) && @request['postingAccountLimit'].between?(1, 10_000)
  end

  def validate_expiry!
    if @request['kind'] == 'renewal_grace'
      validate_grace_expiry!
    else
      raise Invalid unless Hashing.hash?(@request['targetCoverageHash']) && @request['expiresAt'] == @request['termEnd']
    end
  end

  def validate_grace_expiry!
    raise Invalid unless @request['targetCoverageHash'].nil? && Record.positive?(@request['firstFailedAt']) &&
                         @request['dueAt'] == @request['firstFailedAt'] + 604_800 &&
                         @request['expiresAt'] == [@request['dueAt'], @request['termEnd']].min
  end

  def validate_receipt!
    fields = %w[version organizationId operationId requestHash rootManifestHash roots targetPointerHash]
    roots = @receipt['roots']
    raise Invalid unless @receipt.keys.sort == fields.sort && @receipt.values_at('version', 'organizationId', 'operationId', 'requestHash') ==
                                                              [1, @organization, @authority['operationId'], @row['requestHash']]
    raise Invalid unless Hashing.digest(@receipt) == @row['receiptHash'] && roots.is_a?(Array) && roots.size <= 10_000

    validate_roots!(roots)
  end

  def validate_roots!(roots)
    raise Invalid unless roots.all? { |root| valid_root?(root) } &&
                         roots.uniq { |root| root.values_at('rootId', 'rootGeneration') }.size == roots.size &&
                         Hashing.digest(roots) == @receipt['rootManifestHash'] && Hashing.hash?(@receipt['targetPointerHash'])
  end

  def valid_root?(root)
    root.is_a?(Hash) && root.keys.sort == Toybaco::Growth::PostingRenewalInventory::ROOT_FIELDS.sort
  end
end
