# frozen_string_literal: true

require_relative 'posting_renewal_context'
require_relative 'posting_preparation_context'
require_relative 'ordinary_renewal_evidence'

# Dedicated renewal admission. A stale failed-invoice key never becomes a
# blanket active/past_due exception in new-purchase or ordinary authority code.
class Toybaco::Growth::PostingRenewalExecution
  include Toybaco::Growth::PostingPreparationContext
  include Toybaco::Growth::PostingRenewalContext

  def initialize(account, prepared, environment:, now:)
    @account = account
    @prepared = prepared
    @environment = environment
    @now = now
    @value = prepared.fetch('posting_renewal')
    @user = User.unscoped.find_by(id: @value.fetch('owner_id'))
  end

  def snapshot!
    raise Record::Invalid unless @environment['TOYBACO_POSTING_RENEWAL_ENABLED'] == 'true' && @value.dig('evidence', 'expires_at') > @now.to_i

    authorize!
    Toybaco::Growth::PostingStopContext.guard_admission!(@account.id)
    Toybaco::Growth::PostingPrincipal.validate!(@account, @prepared.fetch('principal'), now: @now)
    validate_local_binding!({ 'binding' => @prepared.fetch('binding') }, @prepared)
    validate_holds!
    validate_coverage!(context, @value.fetch('evidence'))
    @prepared
  end

  def verify_provider!(client)
    evidence = Toybaco::Growth::OrdinaryRenewalEvidence.new(source, client: client, now: @now)
                                                       .verify!(kind: @value.fetch('kind'), failure: @value.dig('evidence', 'failure'))
    raise Record::Invalid unless evidence.except('verified_at') == @value.fetch('evidence').except('verified_at')
  end

  private

  def source
    { 'binding' => @value.fetch('source_binding'), 'kind' => @value.fetch('source_kind'),
      'period' => @value['source_period'], 'recovery' => @value['recovery'], 'previous_upgrade' => @value['previous_upgrade'],
      'authority_hash' => @value['source_authority_hash'] }
  end

  def context
    failure = @value.dig('evidence', 'failure')
    fact = failure && Toybaco::Growth::OrdinaryRenewalFact.read!(failure.fetch('operation_id'), account: @account, now: @now)
    raise Record::Invalid unless fact == failure

    { 'source' => source, 'fact' => fact,
      'paid_coverage' => attributes[Toybaco::Growth::PaidPeriod::KEY]&.except('current_period_start', 'current_base_limit') }
  end

  def validate_holds!
    hold, returned = source_hold!(attributes)
    raise Record::Invalid unless hold.fetch('receipt_hash') == @prepared.fetch('inbox_hold_hash') &&
                                 returned.fetch('receipt_hash') == @prepared.fetch('free_return_hash') &&
                                 returned.fetch('posting').values_at('organization_id', 'transition_id', 'receipt_hash') ==
                                 @prepared.fetch('posting').values_at('organization_id', 'transition_id', 'receipt_hash')
  end
end
