# frozen_string_literal: true

require_relative 'posting_paid_upgrade_billing'

module Toybaco::Growth::PostingPaidUpgradeContext
  include Toybaco::Growth::PostingPaidUpgradeBilling
  Record = Toybaco::Growth::PostingPreparationRecord
  Journal = Toybaco::Growth::PostingPaidUpgradeRecord
  Authority = Toybaco::Growth::PostingAuthorityRecord
  Pointer = Toybaco::Growth::PostingAuthorityState
  Execution = Toybaco::Growth::PostingExecutionContext
  Fence = Toybaco::Growth::PostingPaidUpgradeFence
  Terms = Toybaco::Growth::PostingPaidUpgradeTerms

  private

  def upgrade_snapshot!(principal)
    authorize!
    raise Record::Invalid unless Toybaco::PostizSync.organization_id_for(@account) == Toybaco::PostizSync.deterministic_organization_id(@account.id)
    raise Record::Invalid if Toybaco::Growth::PostingStopContext.pending(@account.id)

    Toybaco::Growth::PostingPrincipal.validate!(@account, principal, now: @now)
    attrs = Toybaco::Entitlements.attributes(@account)
    raise Record::Invalid if Toybaco::Growth::RenewalTransition.pending?(@account) || paid_upgrade_billing_blocked?(attrs)

    hold, returned = source_hold!(attrs)
    { 'principal' => principal, 'binding' => binding!(attrs, returned),
      'contract_hash' => Execution.contract_hash(@account), 'free_return_hash' => returned.fetch('receipt_hash'),
      'inbox_hold_hash' => hold.fetch('receipt_hash'), 'posting_ack' => returned.fetch('posting') }
  end

  def validate_context!(prepared)
    raise Record::Invalid unless prepared.dig('binding', 'mode') == @config.fetch(:mode)

    @posting_paid_recovery = prepared['posting_paid_recovery'] || prepared.dig('posting_renewal', 'recovery')
    state = upgrade_snapshot!(prepared.fetch('principal'))
    raise Record::Invalid unless state.except('posting_ack') == prepared.slice(*state.except('posting_ack').keys) &&
                                 state.fetch('posting_ack').values_at('organization_id', 'transition_id', 'receipt_hash') ==
                                 prepared.fetch('posting').values_at('organization_id', 'transition_id', 'receipt_hash')

    state.slice(*Journal::CONTEXT_FIELDS)
  end

  def source_record!
    Fence.guard!(@account.id)
    pointer = Pointer.current(@account.id, now: @now)
    row = pointer&.authority_id && Authority.find(@account.id, pointer.authority_id, now: @now)
    raise Record::Invalid unless ready_source?(row)

    prepared = Authority.effective_preparation!(row, now: @now)
    validate_context!(prepared)
    [row, prepared, Pointer.fingerprint(pointer)]
  end

  def ready_source?(row)
    row && row.receipt['kind'] != 'renewal_grace' && row.state == 'active' && row.receipt['owner_id'] == @user.id &&
      row.receipt['expires_at'] > @now.to_i &&
      row.postiz_receipt&.values_at('state', 'current') == ['ready', true]
  end

  def journal_receipt(source, prepared, pointer, target, operation_id)
    value = { 'version' => 1, 'account_id' => @account.id, 'operation_id' => operation_id, 'owner_id' => @user.id,
              'source_authority_id' => source.authority_id, 'source_authority_hash' => source.receipt['receipt_hash'],
              'source_postiz_hash' => source.postiz_receipt.fetch('authorityHash'),
              'source_contract_hash' => prepared['contract_hash'], 'target_contract_hash' => target_hash(target),
              'source_pointer_hash' => pointer, 'source_context' => prepared.slice(*Journal::CONTEXT_FIELDS),
              'target_binding' => target, 'created_at' => @now.to_i }
    value['handoff'] = handoff(source, prepared, target, value)
    value.merge('receipt_hash' => Record.digest(value))
  end

  def handoff(source, prepared, target, journal)
    old = prepared['binding']
    coverage = old['coverage']
    { 'accountId' => @account.id, 'organizationId' => prepared.dig('posting', 'organization_id'),
      'operationId' => journal['operation_id'], 'sourceAuthorityId' => source.authority_id,
      'sourceAuthorityHash' => journal['source_postiz_hash'], 'expectedPointerHash' => source.postiz_receipt['pointerHash'],
      'journalHash' => Record.digest(journal), 'periodHash' => Record.digest(coverage.slice('term_start', 'term_end', 'anchor')),
      'sourceCoverageHash' => Record.digest(coverage), 'targetCoverageHash' => Record.digest(target['coverage']),
      'sourceBindingHash' => journal['source_contract_hash'], 'targetBindingHash' => journal['target_contract_hash'],
      'sourcePrincipalHash' => Record.digest(prepared['principal']), 'selectionHash' => Record.digest(prepared['keep_ids']),
      'expiresAt' => source.receipt['expires_at'] }.merge(handoff_limits(old, target))
  end

  def handoff_limits(old, target)
    { 'sourceRank' => Terms.rank(old['contract']), 'targetRank' => Terms.rank(target['contract']),
      'sourcePostingLimit' => Terms.limits(old['contract']).first, 'targetPostingLimit' => Terms.limits(target['contract']).first,
      'sourceScheduledLimit' => Terms.limits(old['contract']).last, 'targetScheduledLimit' => Terms.limits(target['contract']).last }
  end

  def validate_source_journal!(row)
    Journal.validate!(row, now: @now)
    source = Authority.find(@account.id, row.receipt['source_authority_id'], now: @now)
    prepared = Authority.effective_preparation!(source, now: @now)
    raise Record::Invalid unless validate_context!(prepared) == row.receipt['source_context'] &&
                                 Pointer.fingerprint(Pointer.current(@account.id, now: @now)) == row.receipt['source_pointer_hash']

    prepared
  end

  def verify_target!(row)
    raise Record::Invalid if Account.connection.transaction_open?

    @subscription = @client.retrieve_subscription(row.receipt.dig('source_context', 'binding', 'subscription_id'))
    @now = @clock.call
    candidate = Terms.target(@subscription, row.receipt['source_context'], @account, now: @now)
    raise Record::Invalid unless candidate == row.receipt['target_binding']
  end

  def capture_target_principal!
    owner = Toybaco::Growth::PostingPrincipal.owner_id!(@account)
    raise Record::Invalid unless owner == @user.id

    member = Toybaco::Growth::PostingPrincipal.capture_member!(@account, owner, owner, @now)
    { 'version' => 1, 'account_id' => @account.id, 'owner_id' => owner, 'actor_id' => owner, 'members' => [member] }
  end

  def validate_target_journal!(row)
    Journal.validate!(row, now: @now)
    target = Authority.find(@account.id, row.application['authorityId'], now: @now)
    prepared = Authority.effective_preparation!(target, now: @now)
    raise Record::Invalid unless validate_context!(prepared) == row.applied_context

    target
  end
end
