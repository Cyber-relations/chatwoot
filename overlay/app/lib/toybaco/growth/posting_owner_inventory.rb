# frozen_string_literal: true

require_relative 'retention_inventory'
require_relative 'posting_authority_record'
require_relative 'posting_execution_context'

# Classifies saved reservations for the owner UI. No admission, provider read,
# principal creation or authority refresh occurs while reading this inventory.
class Toybaco::Growth::PostingOwnerInventory
  Record = Toybaco::Growth::PostingPreparationRecord
  Authority = Toybaco::Growth::PostingAuthorityRecord
  Pointer = Toybaco::Growth::PostingAuthorityState

  def initialize(account, user, connector: nil, clock: -> { Time.now.utc })
    @account = account
    @user = user
    @connector = connector
    @clock = clock
  end

  def read
    Account.uncached do
      before = snapshot
      rows = Toybaco::Growth::RetentionInventory.new(@account, connector: @connector, authority_context: before[:context]).read
      raise Record::Invalid unless snapshot == before

      rows
    end
  end

  private

  def snapshot
    Account.transaction do
      @account = Toybaco::Growth::PostingPrincipal.locked_account!(@account.id)
      raise Record::Invalid unless @account.active? && Toybaco::BillingAccess.permissions(@account, @user)[:can_manage_billing]

      current_context
    end
  rescue ActiveRecord::LockWaitTimeout
    raise Toybaco::Growth::PostingExecutionContext::Busy
  end

  def current_context
    now = @clock.call
    pointer = Pointer.current(@account.id, now: now)
    contract = Toybaco::Growth::PostingExecutionContext.contract_hash(@account)
    result = { pointer: Pointer.fingerprint(pointer), contract: contract, context: nil }
    return result unless pointer&.authority_id

    row = Authority.find(@account.id, pointer.authority_id, now: now)
    raise Record::Invalid unless row && row.state == 'active' && row.receipt['owner_id'] == @user.id

    prepared = Authority.effective_preparation!(row, now: now)
    principal = prepared.fetch('principal')
    Toybaco::Growth::PostingPrincipal.validate!(@account, principal, now: now)
    raise Record::Invalid unless contract == prepared.fetch('contract_hash')

    result.merge(context: { 'ownerId' => @user.id, 'actorId' => @user.id,
                            'principalHash' => Record.digest(principal), 'contractHash' => contract })
  end
end
