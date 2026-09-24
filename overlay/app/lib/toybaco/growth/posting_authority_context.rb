# frozen_string_literal: true

module Toybaco::Growth::PostingAuthorityContext
  Record = Toybaco::Growth::PostingPreparationRecord
  PreparationProtocol = Toybaco::Growth::PostingPreparationProtocol
  Ack = Toybaco::Growth::PostingPreparationAck
  Pointer = Toybaco::Growth::PostingAuthorityState

  private

  def owned_preparation!(request_id)
    raise Record::Invalid unless Record.hash?(request_id)

    locked do
      authorize!
      prepared = Record.find(@account.id, request_id, now: @now)
      raise Record::Invalid unless prepared && prepared['owner_id'] == @user.id

      config = PreparationProtocol.configuration(@environment)
      payload = PreparationProtocol.request(prepared, @account.id, config: config, now: @now)
      ack = Ack.find(prepared, payload, now: @now)
      raise Record::Invalid unless ack

      [prepared, ack]
    end
  end

  def source
    Toybaco::Growth::PostingAuthoritySource.new(@account, connector: @connector)
  end

  def current_preparation!(prepared)
    state = source_snapshot(prepared.fetch('principal'))
    validate_rails_preparation!(prepared, state)
    raise Record::Invalid unless state.fetch('posting').except('available_ids', 'pointer_hash') == prepared.fetch('posting')

    state
  end

  def current_authority_snapshot!(row, prepared)
    state = if prepared.key?('posting_renewal')
              renewal_snapshot!(prepared)
            else
              source_snapshot(prepared.fetch('principal')).tap { |value| validate_rails_preparation!(prepared, value) }
            end
    stable = state.fetch('posting').except('available_ids', 'pointer_hash', 'inventory_hash')
    raise Record::Invalid unless stable == prepared.fetch('posting').except('inventory_hash') &&
                                 state.dig('posting', 'pointer_hash') == row.postiz_receipt.fetch('pointerHash')

    state
  end

  def renewal_snapshot!(prepared)
    reader = Toybaco::Growth::PostingRenewalExecution.new(@account, prepared, environment: @environment, now: @now)
    locked { reader.snapshot! }
    context = { 'ownerId' => @user.id, 'actorId' => @user.id, 'principalHash' => Record.digest(prepared['principal']),
                'contractHash' => prepared['contract_hash'] }
    posting = source.read(owner_id: @user.id, authority_context: context)
    locked { reader.snapshot! }
    { 'posting' => posting }
  end

  def validate_rails_preparation!(prepared, state = rails_snapshot!(prepared.fetch('principal')))
    raise Record::Invalid unless state.except('posting_ack', 'posting') == prepared.slice(*state.except('posting_ack', 'posting').keys)
    raise Record::Invalid unless state.fetch('posting_ack').values_at('organization_id', 'transition_id', 'receipt_hash') ==
                                 prepared.fetch('posting').values_at('organization_id', 'transition_id', 'receipt_hash')

    state
  end

  def activation_snapshot(prepared, ack)
    state = current_preparation!(prepared)
    { 'preparation_hash' => prepared.fetch('receipt_hash'), 'ack_hash' => ack.fetch('receipt_hash'),
      'expected_rails_pointer_hash' => locked { Pointer.fingerprint(Pointer.current(@account.id, now: @now)) },
      'expected_postiz_pointer_hash' => state.dig('posting', 'pointer_hash'),
      'expires_at' => prepared.dig('binding', 'coverage', 'term_end'),
      'scheduled_posts_per_account' => prepared.dig('binding', 'contract', 'entitlements', 'limits', 'scheduled_posts_per_account') }
  end
end
