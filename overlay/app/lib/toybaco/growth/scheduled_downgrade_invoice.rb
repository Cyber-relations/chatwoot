# frozen_string_literal: true

require_relative 'ordinary_renewal_evidence'

# A distinct cause: current invoice uses the scheduled lower price; the paid
# predecessor is checked against the unchanged source contract.
class Toybaco::Growth::ScheduledDowngradeInvoice < Toybaco::Growth::OrdinaryRenewalEvidence
  def initialize(source, reservation:, client:, now:)
    @original = source.deep_dup
    @reservation = reservation.deep_dup
    target = source.fetch('binding').merge('contract' => reservation.fetch('target'))
    super(source.merge('binding' => target), client: client, now: now)
  end

  def self.subscription_hash(subscription)
    value = subscription.deep_dup
    invoice = value['latest_invoice']
    value['latest_invoice'] = invoice.except('hosted_invoice_url', 'invoice_pdf') if invoice.is_a?(Hash)
    Record.digest(value)
  end

  private

  def validate_subscription_state!(sub)
    raise Invalid unless sub.values_at('collection_method', 'pause_collection', 'pending_update', 'cancel_at_period_end', 'cancel_at') ==
                         ['charge_automatically', nil, nil, false, nil]
    raise Invalid unless paid? ? sub['status'] == 'active' : %w[active past_due].include?(sub['status'])
  end

  def validate_period!(id, starts, ends)
    validate_invoice_period!(id, starts, ends)
    raise Invalid unless @reservation.values_at('period_start', 'period_end') == [starts, ends]
  end

  def validate_continuation!(previous)
    source = @original.dig('binding', 'contract')
    raise Invalid unless %w[plan_id plan_version cycle stripe_price_id].all? { |key| previous[key] == source[key] }
    raise Invalid unless previous['normal_limit'] == source.dig('entitlements', 'limits', 'ai_generations')
  end

  def verify_invoice!
    invoice = @client.retrieve_invoice(@period.fetch('invoice_id'))
    validator = Toybaco::Growth::OrdinaryRenewalInvoice.new(@binding, @period)
    validator.validate!(invoice, paid: paid?)
    original = Toybaco::Growth::OrdinaryRenewalInvoice.new(@original.fetch('binding'), @period)
    original.previous!(@client.retrieve_invoice(previous_coverage.fetch('invoice_id')), previous_coverage)
    verify_customer!
    coverage = paid? ? paid_coverage!(invoice) : unpaid!(invoice)
    result(coverage).merge('kind' => paid? ? 'scheduled_downgrade_paid' : 'scheduled_downgrade_grace',
                           'subscription_hash' => self.class.subscription_hash(@subscription),
                           'invoice_hash' => Record.digest(invoice.except('hosted_invoice_url', 'invoice_pdf')))
  end
end
