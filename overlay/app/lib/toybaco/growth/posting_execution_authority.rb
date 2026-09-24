# frozen_string_literal: true

require_relative 'posting_authority'
require_relative 'posting_execution_protocol'
require_relative 'posting_renewal_execution'
require_relative 'posting_paid_upgrade_billing'

# This adapter is called with the Account row locked. Postiz holds a durable
# reserved step before asking for admission, so no HTTP occurs inside this lock.
class Toybaco::Growth::PostingExecutionAuthority
  include Toybaco::Growth::PostingPreparationContext
  Authority = Toybaco::Growth::PostingAuthorityRecord
  Pointer = Toybaco::Growth::PostingAuthorityState
  Protocol = Toybaco::Growth::PostingPreparationProtocol
  Ack = Toybaco::Growth::PostingPreparationAck

  def initialize(account, execution, environment:, now:)
    @account = account
    @execution = execution
    @environment = environment
    @now = now
  end

  def snapshot!(continuation: false)
    row = Authority.find(@account.id, @execution.fetch('authorityId'), now: @now)
    validate_pointer!(row)

    prepared = Authority.preparation!(row, now: @now)
    @user = User.unscoped.find_by(id: prepared.fetch('owner_id'))
    raise Record::Invalid unless @user && @execution.values_at('accountId', 'organizationId', 'ownerId', 'actorId') ==
                                          [@account.id, prepared.dig('posting', 'organization_id'), @user.id, @user.id]

    verify_wire!(row, prepared)
    prepared = Authority.effective_preparation!(row, now: @now)
    continuation ? validate_continuation!(prepared) : validate_admission!(row, prepared)
    prepared
  end

  def validate_pointer!(row)
    raise Record::Invalid unless row && row.state == 'active' && Pointer.current(@account.id, now: @now)&.authority_id == row.authority_id
  end

  def verify_wire!(row, prepared)
    config = Protocol.configuration(@environment)
    payload = Protocol.request(prepared, @account.id, config: config, now: @now)
    ack = Ack.find(prepared, payload, now: @now)
    raise Record::Invalid unless ack

    wire = Authority.wire(row, ack, now: @now)
    raise Record::Invalid unless @execution.values_at('railsAuthorityHash', 'authorityHash') ==
                                 [row.receipt['receipt_hash'], Record.digest(wire)]

    receipt = row.postiz_receipt
    raise Record::Invalid unless receipt.is_a?(Hash) && receipt.values_at('authorityId', 'authorityHash', 'state', 'current', 'execute') ==
                                                        [row.authority_id, Record.digest(wire), 'ready', true, false]
  end

  def validate_admission!(row, prepared)
    raise Record::Invalid unless row.receipt.fetch('expires_at') > @now.to_i

    if prepared.key?('posting_renewal')
      Toybaco::Growth::PostingRenewalExecution.new(@account, prepared, environment: @environment, now: @now).snapshot!
      return
    end

    @paid_recovery = prepared['posting_paid_recovery'] if row.receipt['operation'] == 'paid_upgrade'
    state = rails_snapshot!(prepared.fetch('principal'))
    raise Record::Invalid unless state.except('posting_ack') == prepared.slice(*state.except('posting_ack').keys)
    raise Record::Invalid unless state.fetch('posting_ack').values_at('organization_id', 'transition_id', 'receipt_hash') ==
                                 prepared.fetch('posting').values_at('organization_id', 'transition_id', 'receipt_hash')
  end

  def validate_continuation!(prepared)
    # Only the execution adapter may choose this after it has locked and
    # verified the matching MAIN pending row. It cannot start a new root.
    authorize!
    raise Record::Invalid unless Toybaco::Growth::PostingExecutionContext.contract_hash(@account) == prepared.fetch('contract_hash')

    Toybaco::Growth::PostingPrincipal.validate!(@account, prepared.fetch('principal'), now: @now)
  end

  def self.verify_provider!(account, prepared, client:, environment:, now:)
    if prepared.key?('posting_renewal')
      return Toybaco::Growth::PostingRenewalExecution.new(account, prepared, environment: environment, now: now).verify_provider!(client)
    end

    object = new(account, {}, environment: environment, now: now)
    object.instance_variable_set(:@client, client)
    object.send(:verify_provider!, prepared)
  end

  private

  def blocked_billing?(attrs)
    return super unless @paid_recovery

    Toybaco::Growth::PostingPaidUpgradeBilling.blocked?(attrs, recovery: @paid_recovery, environment: @environment) { |candidate| super(candidate) }
  end
end
