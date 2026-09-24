# frozen_string_literal: true

# Caller holds Account NOWAIT/read-committed, under the subscription session lock.
module Toybaco::Growth::RenewalDispatchSource
  Record = Toybaco::Growth::PostingPreparationRecord
  Pointer = Toybaco::Growth::PostingAuthorityState
  Renewal = Toybaco::Growth::PostingRenewalRecord
  RenewalAuthority = Toybaco::Growth::PostingRenewalAuthority

  private

  def source_context!
    @dispatch.reload
    saved = @dispatch.public_send(@field)
    return verify_source!(saved) if saved

    authorize!
    raise Record::Invalid if Toybaco::Growth::PostingStopContext.pending(@account.id)

    Toybaco::Growth::PostingRenewalFence.guard!(@account.id)
    pointer = Pointer.current(@account.id, now: @now)
    source = dispatch_source(pointer)
    fact = @operation.first_fact_id && Toybaco::Growth::OrdinaryRenewalFact.read!(@operation.id, account: @account, now: @now)
    raise Record::Invalid if @kind == 'renewal_grace' && !fact

    value = dispatch_context_value(source, fact, pointer)
    @dispatch.update!(@field => value)
    verify_source!(value)
  end

  def dispatch_context_value(source, fact, pointer)
    value = { 'version' => 1, 'owner_id' => @user.id, 'source' => source, 'fact' => fact,
              'principal' => dispatch_principal,
              'contract_hash' => Toybaco::Growth::PostingExecutionContext.contract_hash(@account),
              'pointer_hash' => Pointer.fingerprint(pointer) }
    value['receipt_hash'] = Record.digest(value)
    value
  end

  def dispatch_principal
    member = Toybaco::Growth::PostingPrincipal.capture_member!(@account, @user.id, @user.id, @now)
    { 'version' => 1, 'account_id' => @account.id, 'owner_id' => @user.id, 'actor_id' => @user.id, 'members' => [member] }
  end

  def dispatch_source(pointer)
    validate_billing_state!(attributes)
    if pointer&.authority_id
      source = RenewalAuthority.source!(@account.id, pointer.authority_id, now: @now, environment: @environment)
      validate_local_binding!(source, source.fetch('prepared'))
      return source.except('prepared')
    end
    binding = local_binding.merge('coverage' => attributes[Toybaco::Growth::PaidPeriod::KEY]&.except('current_period_start', 'current_base_limit'))
    raise Record::Invalid unless binding['coverage'].is_a?(Hash)

    { 'kind' => 'paid_activation', 'binding' => binding, 'period' => nil,
      'authority_hash' => Record.digest(['non-posting-ordinary-renewal-v1', @account.id, binding]) }
  end

  def verify_source!(value, ready: false)
    validate_dispatch_receipt!(value)
    authorize!
    raise Record::Invalid unless value['owner_id'] == @user.id && value.dig('source', 'binding').except('coverage') == local_binding &&
                                 value['contract_hash'] == Toybaco::Growth::PostingExecutionContext.contract_hash(@account)

    Toybaco::Growth::PostingPrincipal.validate!(@account, value.fetch('principal'), now: @clock.call)
    raise Record::Invalid if Toybaco::Growth::PostingStopContext.pending(@account.id)

    validate_billing_state!(attributes)
    verify_dispatch_pointer!(value, ready)
    verify_dispatch_fact!(value)
    value
  end

  def validate_dispatch_receipt!(value)
    fields = %w[version owner_id source fact principal contract_hash pointer_hash receipt_hash]
    raise Record::Invalid unless value.is_a?(Hash) && value.keys.sort == fields.sort && value['version'] == 1 &&
                                 value['receipt_hash'] == Record.digest(value.except('receipt_hash'))
  end

  def verify_dispatch_pointer!(value, ready)
    pointer = Pointer.current(@account.id, now: @clock.call)
    previous = Renewal.find(@account.id, @request_id, now: @clock.call)
    if previous && %w[applied ready].include?(previous.state)
      verify_transferred_pointer!(value, pointer, previous, ready)
    else
      raise Record::Invalid unless Pointer.fingerprint(pointer) == value['pointer_hash']
      raise Record::Invalid if ready && value.dig('source', 'authority_id')
    end
    Toybaco::Growth::PostingRenewalFence.guard!(@account.id, except_request_id: previous&.request_id)
  end

  def verify_transferred_pointer!(value, pointer, previous, ready)
    raise Record::Invalid if ready && previous.state != 'ready'
    raise Record::Invalid unless pointer&.authority_id == previous.target_authority_id
    return unless previous.state == 'ready'

    target = RenewalAuthority.source!(@account.id, pointer.authority_id, now: @clock.call, environment: @environment)
    raise Record::Invalid unless target['prepared']['principal'] == value['principal']
  end

  def verify_dispatch_fact!(value)
    return unless value['fact']

    current = Toybaco::Growth::OrdinaryRenewalFact.read!(@operation.id, account: @account, now: @clock.call)
    raise Record::Invalid unless current == value['fact']
  end
end
