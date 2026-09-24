# frozen_string_literal: true

# The Postiz adapter authenticates its dedicated response before either DB
# advances. Recovery reuses the immutable operation and never grants execution.
module Toybaco::Growth::PostingRenewalExchange
  Record = Toybaco::Growth::PostingPreparationRecord
  Renewal = Toybaco::Growth::PostingRenewalRecord
  RenewalAuthority = Toybaco::Growth::PostingRenewalAuthority
  Pointer = Toybaco::Growth::PostingAuthorityState

  VERIFIED_PROTOCOL = 'toybaco-posting-renewal-v1'

  private

  def exchange_record!(row)
    unless @transport.respond_to?(:verified_protocol) && @transport.verified_protocol == VERIFIED_PROTOCOL
      raise Toybaco::Growth::PostingRenewal::ProtocolUnavailable
    end

    validate_resume!(row, check_posting: row.state == 'prepared')
    start_transfer!(row) if row.state == 'prepared'
    response = exchange!(row, 'prepare')
    commit_target!(row, response)
    confirm = exchange!(row, 'confirm')
    validate_resume!(row)
    finish_confirmation!(row, confirm)
  end

  def finish_confirmation!(row, confirm)
    locked do
      row.reload
      validate_context_record!(row)
      raise Record::Invalid unless row.state == 'applied' && confirm.except('requestHash',
                                                                            'state') == row.postiz_receipt.except('requestHash', 'state')

      target = Toybaco::GrowthPostingAuthority.find_by!(account_id: row.account_id, authority_id: row.target_authority_id)
      target.update!(postiz_receipt: target_ack(row, confirm), updated_at: @now)
      row.update!(state: 'ready', confirm_receipt: confirm, updated_at: @now)
      result(row)
    end
  end

  def validate_resume!(row, remote_pointer: nil, check_posting: true)
    context = locked { validate_context_record!(row) }
    validate_posting_record!(row, context, remote_pointer) if check_posting

    verified = evidence!(context, row.kind)
    @now = @clock.call
    raise Record::Invalid unless verified.except('verified_at') == row.receipt.fetch('evidence').except('verified_at')

    locked do
      raise Record::Invalid unless validate_context_record!(row) == context

      validate_coverage!(context, verified)
    end
  end

  def validate_posting_record!(row, context, remote_pointer)
    expected = remote_pointer || (row.state == 'applied' ? row.postiz_receipt['targetPointerHash'] : row.receipt['expected_postiz_pointer_hash'])
    recovery = recovery_inventory_scope(row, expected) if remote_pointer || row.state == 'applied'
    posting = posting_snapshot!(context, renewal_recovery: recovery)
    raise Record::Invalid unless posting['pointer_hash'] == expected && posting.except('pointer_hash') == row.receipt['posting']
  end

  def validate_context_record!(row)
    Renewal.validate!(row, now: @now)
    operation = row.receipt.dig('evidence', 'failure', 'operation_id')
    context = context!(row.source_authority_id, operation, row: row)
    source = context.fetch('source')
    raise Record::Invalid unless source['authority_hash'] == row.receipt['source_authority_hash'] &&
                                 source['binding'] == row.receipt['source_binding'] && @now.to_i < row.receipt.dig('evidence', 'expires_at')

    validate_current_record!(row, context)
    context
  end

  def validate_current_record!(row, context)
    expected = row.state == 'applied' ? row.target_authority_id : row.source_authority_id
    raise Record::Invalid unless Pointer.current(@account.id, now: @now)&.authority_id == expected

    expected_hash = row.state == 'applied' ? row.rails_pointer_hash : row.receipt['expected_rails_pointer_hash']
    raise Record::Invalid unless context['pointer_hash'] == expected_hash
  end

  def start_transfer!(row)
    locked do
      row.reload
      validate_context_record!(row)
      raise Record::Invalid unless row.state == 'prepared'
      raise Toybaco::Growth::PostingExecutionContext::Busy if unfinished_executions?

      source = Toybaco::GrowthPostingAuthority.find_by!(account_id: row.account_id, authority_id: row.source_authority_id)
      RenewalAuthority.create!(row, source, now: @now)
      row.update!(state: 'transferring', updated_at: @now)
    end
  end

  def unfinished_executions?
    Toybaco::GrowthPostingExecution.where(account_id: @account.id).where.not(state: %w[completed cancelled]).exists?
  end

  def commit_target!(row, response)
    validate_resume!(row, remote_pointer: response['targetPointerHash'])
    locked do
      row.reload
      validate_context_record!(row)
      raise Toybaco::Growth::PostingExecutionContext::Busy if unfinished_executions?

      if row.state == 'applied'
        raise Record::Invalid unless row.postiz_receipt == response

        next
      end
      raise Record::Invalid unless row.state == 'transferring'

      Pointer.assign!(@account.id, row.target_authority_id, expected: row.receipt['expected_rails_pointer_hash'], now: @now)
      target = Toybaco::GrowthPostingAuthority.find_by!(account_id: row.account_id, authority_id: row.target_authority_id)
      target.update!(state: 'active', postiz_receipt: target_ack(row, response), updated_at: @now)
      pointer_hash = current_pointer_hash
      row.update!(state: 'applied', postiz_receipt: response, rails_pointer_hash: pointer_hash, updated_at: @now)
    end
  end

  def current_pointer_hash
    Pointer.fingerprint(Pointer.current(@account.id, now: @now))
  end
end
