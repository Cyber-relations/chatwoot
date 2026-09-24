# frozen_string_literal: true

require_relative 'posting_paid_upgrade_protocol'
require_relative 'posting_authority_inventory_record'

# Read-only verification of the paid-upgrade edge. Original preparation and
# schedule rows stay immutable; only this typed chain supplies current context.
class Toybaco::Growth::PostingPaidUpgradeInventory
  Record = Toybaco::Growth::PostingAuthorityInventoryRecord
  Hashing = Toybaco::Growth::PostingPreparationRecord
  Protocol = Toybaco::Growth::PostingPaidUpgradeProtocol
  Invalid = Record::Invalid
  EXTRA = %w[kind operationId sourceAuthorityId sourceAuthorityHash handoffReceiptHash contractAppliedHash targetPrincipalHash].freeze
  ROOT_FIELDS = %w[rootId rootGeneration scheduleHash saveRequestId postPayloadHash markerHash state descendantsHash].freeze

  def initialize(connection, authority, authority_hash, request)
    @connection = connection
    @authority = authority
    @authority_hash = authority_hash
    @request = request
    @organization = request.fetch('organizationId')
    @edges = []
    load_chain(authority, authority_hash)
  end

  def context
    edge = @edges.first
    { 'principalHash' => edge.fetch(:application).fetch('targetPrincipalHash'),
      'contractHash' => edge.fetch(:request).fetch('targetBindingHash') }
  end

  def schedule?(row, value)
    target_id = @authority['authorityId']
    target_hash = @authority_hash
    @edges.each do |edge|
      return true if schedule_matches?(row, value, target_id, target_hash)

      validate_schedule_edge!(row, value, edge, target_id, target_hash)
      target_id = edge[:source]['authorityId']
      target_hash = edge[:source_hash]
    end
    return @renewal_anchor.schedule?(row, value) if @renewal_anchor

    schedule_matches?(row, value, target_id, target_hash)
  end

  def schedule_matches?(row, value, target_id, target_hash)
    row['authorityId'] == target_id && value['authorityHash'] == target_hash
  end

  def validate_schedule_edge!(row, value, edge, target_id, target_hash)
    continuation = one('ToybacoPostingScheduleContinuation',
                       '"rootId" = $2 AND "rootGeneration" = $3 AND "targetAuthorityId" = $4',
                       [row.fetch('rootId'), row.fetch('rootGeneration'), target_id])
    root = manifest_root!(edge, row, value)
    raise Invalid unless continuation

    payload = Record.object(continuation.fetch('payload'))
    expected = root.merge('organizationId' => @organization, 'operationId' => edge[:request]['operationId'],
                          'handoffReceiptHash' => edge[:hash], 'sourceAuthorityId' => edge[:source]['authorityId'],
                          'sourceAuthorityHash' => edge[:source_hash], 'targetAuthorityId' => target_id, 'targetAuthorityHash' => target_hash)
    raise Invalid unless payload == expected && Hashing.digest(payload) == continuation['continuationHash']
  end

  def manifest_root!(edge, row, value)
    root = edge[:receipt].fetch('roots').find { |item| item.values_at('rootId', 'rootGeneration') == row.values_at('rootId', 'rootGeneration') }
    expected = value.slice('saveRequestId', 'postPayloadHash').merge('scheduleHash' => row.fetch('scheduleHash'))
    raise Invalid unless root && root.slice(*expected.keys) == expected

    root
  end

  private

  def one(table, condition, values)
    rows = @connection.exec_params("SELECT * FROM \"#{table}\" WHERE \"organizationId\" = $1 AND #{condition}", [@organization] + values).to_a
    raise Invalid unless rows.size <= 1

    rows.first
  end

  def load_chain(authority, fingerprint)
    while authority['kind'] == 'paid_upgrade'
      raise Invalid if @edges.size >= 2

      edge = read_edge(authority, fingerprint)
      @edges << edge
      authority, fingerprint = edge.values_at(:source, :source_hash)
    end
    if authority['kind'] == 'renewal_paid'
      @renewal_anchor = Toybaco::Growth::PostingRenewalInventory.new(@connection, authority, fingerprint, @request)
    else
      raise Invalid unless authority.keys.sort == Toybaco::Growth::PostingAuthorityRecord::WIRE_FIELDS.sort
    end
    validate_context_chain!
  end

  def read_edge(authority, fingerprint)
    raise Invalid unless authority.keys.sort == (Toybaco::Growth::PostingAuthorityRecord::WIRE_FIELDS + EXTRA).sort &&
                         Hashing.digest(authority) == fingerprint

    row = one('ToybacoPostingPaidUpgrade', '"operationId" = $2', [authority.fetch('operationId')])
    raise Invalid unless row && row['state'] == 'ready'

    request, receipt, application = %w[request receipt application].map { |key| Record.object(row.fetch(key)) }
    validate_handoff!(row, request, receipt, application)
    source_row = source_row!(request)
    source = Record.object(source_row.fetch('payload'))
    validate_source!(source_row, source, request)
    expected = target_payload(source, source_row, request, row, application)
    raise Invalid unless expected == authority

    { request: request, receipt: receipt, application: application, hash: row['receiptHash'], source: source,
      source_hash: source_row['authorityHash'] }
  end

  def source_row!(request)
    source_row = one('ToybacoPostingAuthority', '"authorityId" = $2', [request.fetch('sourceAuthorityId')])
    raise Invalid unless source_row

    source_row
  end

  def target_payload(source, source_row, request, row, application)
    source.merge('authorityId' => application['authorityId'], 'railsAuthorityHash' => application['railsAuthorityHash'],
                 'expectedPointerHash' => request['expectedPointerHash'], 'scheduledPostsPerAccount' => request['targetScheduledLimit'],
                 'kind' => 'paid_upgrade', 'operationId' => request['operationId'], 'sourceAuthorityId' => source['authorityId'],
                 'sourceAuthorityHash' => source_row['authorityHash'], 'handoffReceiptHash' => row['receiptHash'],
                 'contractAppliedHash' => application['contractAppliedHash'], 'targetPrincipalHash' => application['targetPrincipalHash'])
  end

  def validate_handoff!(row, request, receipt, application)
    Protocol.validate_handoff!(request)
    Protocol.validate_application!(application)
    actual = row.values_at('organizationId', 'operationId', 'requestHash', 'receiptHash', 'applicationHash')
    raise Invalid unless actual == [@organization, request['operationId'], Hashing.digest(request), Hashing.digest(receipt),
                                    Hashing.digest(application)]
    raise Invalid unless application['receiptHash'] == row['receiptHash'] &&
                         receipt.values_at('version', 'organizationId', 'operationId', 'requestHash') ==
                         [1, @organization, request['operationId'], row['requestHash']]

    validate_roots!(receipt)
  rescue Hashing::Invalid
    raise Invalid
  end

  def validate_roots!(receipt)
    raise Invalid unless receipt.keys.sort == %w[operationId organizationId requestHash rootManifestHash roots version]

    roots = receipt['roots']
    raise Invalid unless roots.is_a?(Array) && roots.size <= 10_000
    raise Invalid unless roots.all? { |root| valid_root?(root) }

    validate_roots_hash!(roots, receipt['rootManifestHash'])
  end

  def validate_roots_hash!(roots, fingerprint)
    raise Invalid unless roots.uniq { |root| root.values_at('rootId', 'rootGeneration') }.size == roots.size &&
                         fingerprint == Hashing.digest(roots)
  end

  def valid_root?(root)
    root.is_a?(Hash) && root.keys.sort == ROOT_FIELDS.sort
  end

  def validate_source!(row, source, request)
    raise Invalid unless source.values_at('organizationId', 'authorityId') == row.values_at('organizationId', 'authorityId') &&
                         Hashing.digest(source) == row['authorityHash'] && row['authorityHash'] == request['sourceAuthorityHash'] &&
                         source.values_at('accountId', 'expiresAt', 'scheduledPostsPerAccount') ==
                         request.values_at('accountId', 'expiresAt', 'sourceScheduledLimit') &&
                         source.values_at('preparationRequestId', 'preparationReceiptHash') ==
                         @authority.values_at('preparationRequestId', 'preparationReceiptHash')
  end

  def validate_context_chain!
    initial = @renewal_anchor ? @renewal_anchor.context : @request
    context = initial.slice('principalHash', 'contractHash').merge('limit' => initial.fetch('postingAccountLimit'))
    @edges.reverse_each do |edge|
      input = edge[:request]
      raise Invalid unless input.values_at('sourcePrincipalHash', 'sourceBindingHash', 'sourcePostingLimit', 'selectionHash') ==
                           [context['principalHash'], context['contractHash'], context['limit'], Hashing.digest(@request['keepIntegrationIds'])]

      context = { 'principalHash' => edge[:application]['targetPrincipalHash'], 'contractHash' => input['targetBindingHash'],
                  'limit' => input['targetPostingLimit'] }
    end
  end
end
