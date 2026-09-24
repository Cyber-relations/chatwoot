# frozen_string_literal: true

module Toybaco::Growth::PostingPaidUpgradeApplication
  Record = Toybaco::Growth::PostingPreparationRecord
  Journal = Toybaco::Growth::PostingPaidUpgradeRecord
  Authority = Toybaco::Growth::PostingAuthorityRecord
  Pointer = Toybaco::Growth::PostingAuthorityState

  private

  def persist_target!(row, prepared)
    context = upgrade_snapshot!(capture_target_principal!).slice(*Journal::CONTEXT_FIELDS)
    validate_new_context!(row, prepared, context)
    source = Authority.find(@account.id, row.receipt['source_authority_id'], now: @now)
    value = target_receipt(row, source, context)
    row.update!(state: 'applied', application: application(value, context), applied_context: context,
                applied_pointer_hash: Pointer.fingerprint(Pointer.current(@account.id, now: @now)), updated_at: @now)
    created = Toybaco::GrowthPostingAuthority.create!(account_id: @account.id, authority_id: value['authority_id'],
                                                      preparation_request_id: source.preparation_request_id, receipt: value,
                                                      created_at: @now, updated_at: @now)
    Authority.validate!(created, now: @now)
  end

  def validate_new_context!(row, prepared, context)
    raise Record::Invalid unless context['binding'] == row.receipt['target_binding'] &&
                                 context['contract_hash'] == row.receipt['target_contract_hash'] && context['principal'] != prepared['principal']
  end

  def application(value, context)
    { 'receiptHash' => value['handoff_receipt_hash'], 'contractAppliedHash' => value['contract_applied_hash'],
      'targetPrincipalHash' => Record.digest(context['principal']), 'authorityId' => value['authority_id'],
      'railsAuthorityHash' => value['receipt_hash'] }
  end

  def target_receipt(row, source, context)
    value = source.receipt.slice(*Authority::FIELDS).merge(
      'version' => 2, 'operation' => 'paid_upgrade', 'authority_id' => Record.digest(['posting_paid_upgrade', @account.id, row.operation_id]),
      'revision' => row.operation_id, 'created_at' => @now.to_i, 'target_context' => context,
      'scheduled_posts_per_account' => row.receipt.dig('handoff', 'targetScheduledLimit'),
      'expected_rails_pointer_hash' => Pointer.fingerprint(Pointer.current(@account.id, now: @now)),
      'expected_postiz_pointer_hash' => row.receipt.dig('handoff', 'expectedPointerHash')
    )
    value.merge!(target_link(row, source, context))
    value.merge('receipt_hash' => Record.digest(value))
  end

  def target_link(row, source, context)
    { 'source_authority_id' => source.authority_id, 'source_authority_hash' => source.receipt['receipt_hash'],
      'source_postiz_hash' => row.receipt['source_postiz_hash'], 'journal_hash' => row.receipt['receipt_hash'],
      'handoff_receipt_hash' => row.postiz_receipt['receiptHash'],
      'contract_applied_hash' => Record.digest([row.operation_id, row.receipt['source_contract_hash'], context]) }
  end

  def apply_remote!(row)
    verify_target!(row)
    locked { validate_target_journal!(row) }
    response = exchange!(row, 'apply')
    locked do
      target = validate_target_journal!(row)
      validate_target_response!(row, target, response)
      Pointer.assign!(@account.id, target.authority_id, expected: row.applied_pointer_hash, now: @now)
      target.update!(state: 'active', postiz_receipt: authority_response(row, response), updated_at: @now)
      row.update!(state: 'active', postiz_receipt: response, updated_at: @now)
    end
  end

  def confirm_remote!(row)
    verify_target!(row)
    locked { current_target!(row) }
    response = exchange!(row, 'confirm')
    locked do
      target = current_target!(row)
      validate_target_response!(row, target, response)
      raise Record::Invalid unless response['state'] == 'ready' && response['pointerHash'] == row.postiz_receipt['pointerHash']

      target.update!(postiz_receipt: authority_response(row, response), updated_at: @now)
      row.update!(state: 'ready', postiz_receipt: response, updated_at: @now)
    end
  end

  def current_target!(row)
    target = validate_target_journal!(row)
    raise Record::Invalid unless Pointer.current(@account.id, now: @now)&.authority_id == target.authority_id

    target
  end

  def current_result!(row)
    verify_target!(row)
    target = locked { current_target!(row) }
    response = exchange!(row, 'status')
    locked do
      current_target!(row)
      validate_target_response!(row, target, response)
      raise Record::Invalid unless response['state'] == 'ready'
    end
    result(row)
  end

  def validate_target_response!(row, target, response)
    original = Authority.preparation!(target, now: @now)
    config = Toybaco::Growth::PostingPreparationProtocol.configuration(@environment.merge('TOYBACO_POSTING_RELEASE_ENABLED' => 'true'))
    payload = Toybaco::Growth::PostingPreparationProtocol.request(original, @account.id, config: config, now: @now)
    ack = Toybaco::Growth::PostingPreparationAck.find(original, payload, now: @now)
    raise Record::Invalid unless ack && response['current'] && response['authorityHash'] == Record.digest(Authority.wire(target, ack, now: @now)) &&
                                 response['authorityId'] == row.application['authorityId']
  end

  def authority_response(row, response)
    { 'organizationId' => row.receipt.dig('handoff', 'organizationId'), 'authorityId' => response['authorityId'],
      'authorityHash' => response['authorityHash'], 'state' => response['state'] == 'ready' ? 'ready' : 'pending',
      'pointerHash' => response['pointerHash'], 'current' => response['current'], 'execute' => false }
  end
end
