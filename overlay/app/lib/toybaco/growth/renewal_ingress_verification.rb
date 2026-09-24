# frozen_string_literal: true

require_relative 'renewal_failure_receipt'
require_relative 'renewal_ingress'

# Uses the same current-subscription and first-failure rules as the older
# signed payment endpoint. This never invokes Settlement, Stop, holds or Free.
class Toybaco::Growth::RenewalIngressVerification < Toybaco::Growth::RenewalFailureReceipt
  def record!
    raise Unresolved if Account.connection.transaction_open?

    Toybaco::Growth::BillingReceipt.verify!(@receipt)
    @fact = Toybaco::Growth::RenewalIngress.verify!(Toybaco::RenewalInvoiceFact.find_by(billing_event_id: @receipt.id), @receipt)
    @operation = Toybaco::RenewalOperation.find(@fact.renewal_operation_id)
    verify_operation!
    @current_subscription = @client.retrieve_subscription(@invoice.fetch('subscription')).deep_dup
    Account.uncached { super }
  end

  private

  def retrieve_subscription
    @current_subscription
  end

  def verify_operation!
    expected = @fact.attributes.slice('mode', 'subscription_id', 'customer_id', 'invoice_id')
    raise Toybaco::Growth::PaymentSignature::Invalid unless @operation.attributes.slice(*expected.keys) == expected
  end

  def record_for!(account)
    raise Unresolved unless Account.connection.select_value('SHOW transaction_isolation') == 'read committed'

    @operation.lock!
    use_first_fact!
    raise Unresolved if @operation.account_id && @operation.account_id != account.id

    result = super
    attributes = { account_id: account.id, result: result, verified_at: @now }
    attributes.merge!(verified_state(account, result))
    @operation.update!(attributes)
    result
  end

  def use_first_fact!
    return unless @operation.first_fact_id

    first = Toybaco::RenewalInvoiceFact.find(@operation.first_fact_id)
    origin = Toybaco::BillingEvent.find(first.billing_event_id)
    Toybaco::Growth::BillingReceipt.verify!(origin)
    Toybaco::Growth::RenewalIngress.verify!(first, origin)
    raise Unresolved unless first.renewal_operation_id == @operation.id && Toybaco::Growth::RenewalIngress.first_failure?(first)
    raise Unresolved unless @operation.first_failed_at == first.event_created_at && @operation.due_at == first.event_created_at + 7.days

    @receipt = origin
    @invoice = origin.snapshot.fetch('data').fetch('object')
  end

  def verify_subscription!(subscription, attrs)
    super
    @observed = subscription
  end

  def verified_state(account, result)
    return { state: 'outside_terms' } if result == 'outside_growth_terms'
    return { state: 'waiting_first' } if result == 'awaiting_first_failure'
    return { state: resolved_invoice? ? 'resolved_observation' : 'attention' } if result == 'invoice_already_resolved'

    return { state: 'attention', result: 'failure_evidence_mismatch' } unless failure_matches?(account)

    source = { 'contract' => Toybaco::Entitlements.contract_for(account), 'subscription_id' => @fact.subscription_id,
               'customer_id' => @fact.customer_id, 'mode' => @fact.mode }
    { state: 'observed_failure', source_hash: Toybaco::Growth::BillingReceipt.snapshot_digest(source) }
  end

  def failure_matches?(account)
    failure = Toybaco::Entitlements.attributes(account)[KEY]
    failure.is_a?(Hash) && failure['invoice_id'] == @fact.invoice_id && failure['subscription_id'] == @fact.subscription_id &&
      @operation.first_failed_at&.to_i == failure['first_failed_at'] && @operation.due_at&.to_i == failure['grace_ends_at']
  end

  def resolved_invoice?
    invoice = @observed && @observed['latest_invoice']
    invoice.is_a?(Hash) && invoice['id'] == @fact.invoice_id && %w[paid void uncollectible].include?(invoice['status'])
  end
end
