# frozen_string_literal: true

require_relative 'posting_renewal'
require_relative 'renewal_dispatch_source'
require_relative 'paid_period'
require_relative 'renewal_dispatch_provider'

# The persisted local source survives coverage commit / remote response loss.
# PostingRenewal owns the separate immutable cross-database exchange.
class Toybaco::Growth::RenewalDispatchContinuation < Toybaco::Growth::PostingRenewal
  include Toybaco::Growth::RenewalDispatchSource
  Dispatch = Toybaco::Growth::RenewalDispatch

  def call(row, operation, kind:)
    @dispatch = row
    @operation = operation
    @kind = kind
    @request_id = Dispatch.request_id(operation, kind)
    @field = kind == 'renewal_paid' ? 'paid_context' : 'grace_context'
    @now = @clock.call
    raise Record::Invalid if Account.connection.transaction_open?

    Toybaco::Checkout::PlanChangeLock.call(@account) do
      Account.uncached { advance_continuation! }
    end
  end

  private

  def advance_continuation!
    context = locked { source_context! }
    observed = Toybaco::Growth::RenewalDispatchProvider.new(@client)
    evidence = Toybaco::Growth::OrdinaryRenewalEvidence.new(context.fetch('source'), client: observed, now: @now)
                                                       .verify!(kind: @kind, failure: context['fact'])
    if @kind == 'renewal_paid'
      locked { observe_paid!(context, evidence, observed.subscription) }
    else
      locked do
        verify_source!(context)
        verify_dispatch_coverage!(context, evidence)
      end
    end
    source_id = context.dig('source', 'authority_id')
    exchange_continuation!(context, source_id) if source_id
    locked { verify_source!(context, ready: true) }
    @kind == 'renewal_paid' ? 'paid_ready' : 'grace_ready'
  end

  def exchange_continuation!(context, source_id)
    previous = Renewal.find(@account.id, @request_id, now: @clock.call)
    unless previous
      prepare!(kind: @kind, request_id: @request_id, source_authority_id: source_id,
               operation_id: context.dig('fact', 'operation_id'))
    end
    result = deliver!(request_id: @request_id)
    raise Record::Invalid unless result['state'] == 'ready' && result['execute'] == false
  end

  def verify_dispatch_coverage!(context, evidence)
    snapshot = context.merge('paid_coverage' => attributes[Toybaco::Growth::PaidPeriod::KEY]&.except('current_period_start', 'current_base_limit'))
    validate_coverage!(snapshot, evidence)
  end

  def observe_paid!(context, evidence, subscription)
    verify_source!(context)
    coverage = Toybaco::Growth::PaidCoverage.new(subscription, context.dig('source', 'binding', 'contract')).verified
    raise Record::Invalid unless coverage == evidence['coverage'] && subscription['id'] == @operation.subscription_id &&
                                 subscription['customer'] == @operation.customer_id && subscription['livemode'] == (@operation.mode == 'live')

    Toybaco::Growth::PaidPeriod.new(@account, now: @clock.call).observe!(subscription)
    saved = attributes[Toybaco::Growth::PaidPeriod::KEY]&.except('current_period_start', 'current_base_limit')
    raise Record::Invalid unless saved == evidence['coverage']

    verify_dispatch_coverage!(context, evidence)
  end
end
