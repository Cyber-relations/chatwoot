# frozen_string_literal: true

require_relative 'posting_renewal_inventory'

# A completed MAIN may precede several renewals. Both authority proofs must
# bind the same original schedule; neither the operation nor schedule is cloned.
class Toybaco::Growth::PostingRenewalExecutionProof
  Record = Toybaco::Growth::PostingPreparationRecord
  Authority = Toybaco::Growth::PostingAuthorityRecord
  InventoryRecord = Toybaco::Growth::PostingAuthorityInventoryRecord

  def initialize(execution, previous, now:, connector: nil)
    @execution = execution
    @previous = previous
    @now = now
    @connector = connector || -> { PG.connect(ENV.fetch('TOYBACO_POSTIZ_DATABASE_URL'), connect_timeout: 5) }
  end

  def valid?
    return false unless @execution['step'] == 'COMMENT'

    stable = Toybaco::Growth::PostingExecutionV3::GROUP - %w[authorityId authorityHash railsAuthorityHash]
    return false unless @execution.slice(*stable) == @previous.slice(*stable)

    rows = [@execution, @previous].map { |input| local_row!(input) }
    return false unless Toybaco::Growth::PostingRenewalAuthority.typed?(rows.first.receipt)

    read_schedule!(rows)
  end

  private

  def read_schedule!(rows)
    @connection = @connector.call
    @connection.exec('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY')
    @connection.exec("SET LOCAL statement_timeout = '5s'")
    verify_schedule!(rows)
    @connection.exec('COMMIT')
    true
  ensure
    @connection&.close unless @connection&.finished?
  end

  def local_row!(input)
    row = Authority.find(input.fetch('accountId'), input.fetch('authorityId'), now: @now)
    raise Record::Invalid unless row && row.receipt['receipt_hash'] == input['railsAuthorityHash'] &&
                                 row.postiz_receipt&.fetch('authorityHash') == input['authorityHash']

    row
  end

  def one(table, fields)
    keys = fields.keys
    where = keys.each_with_index.map { |key, index| "\"#{key}\" = $#{index + 1}" }.join(' AND ')
    rows = @connection.exec_params("SELECT * FROM \"#{table}\" WHERE #{where}", fields.values).to_a
    raise Record::Invalid unless rows.one?

    rows.first
  end

  def verify_schedule!(rows)
    organization = @execution.fetch('organizationId')
    schedule = one('ToybacoPostingSchedule', 'organizationId' => organization, 'rootId' => @execution['rootId'],
                                             'rootGeneration' => @execution['rootGeneration'])
    value = InventoryRecord.object(schedule.fetch('payload'))
    raise Record::Invalid unless schedule['scheduleHash'] == @execution['scheduleHash'] && Record.digest(value) == schedule['scheduleHash'] &&
                                 value['saveRequestId'] == @execution['saveRequestId']

    rows.zip([@execution, @previous]).each { |row, input| verify_authority!(row, input, schedule, value) }
  end

  def verify_authority!(row, input, schedule, value)
    org = @execution.fetch('organizationId')
    authority = one('ToybacoPostingAuthority', 'organizationId' => org, 'authorityId' => row.authority_id)
    payload = InventoryRecord.object(authority.fetch('payload'))
    raise Record::Invalid unless Record.digest(payload) == input['authorityHash'] && authority['authorityHash'] == input['authorityHash']

    return verify_original!(row, input, schedule, value) if row.receipt['version'] == 1

    verify_typed!(row, input, payload, schedule, value)
  end

  def verify_original!(row, input, schedule, value)
    return unless row.receipt['version'] == 1
    raise Record::Invalid unless schedule['authorityId'] == row.authority_id && value['authorityHash'] == input['authorityHash']

    return
  end

  def verify_typed!(row, input, payload, schedule, value)
    org = @execution.fetch('organizationId')
    original = one('ToybacoPostingPreparation', 'organizationId' => org, 'requestId' => row.preparation_request_id)
    request = InventoryRecord.preparation!(original, payload, row.account_id, now: @now)
    reader = payload['kind'] == 'paid_upgrade' ? Toybaco::Growth::PostingPaidUpgradeInventory : Toybaco::Growth::PostingRenewalInventory
    raise Record::Invalid unless reader.new(@connection, payload, input['authorityHash'], request).schedule?(schedule, value)
  end
end
