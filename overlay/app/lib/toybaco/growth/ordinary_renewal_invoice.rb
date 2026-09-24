# frozen_string_literal: true

require_relative 'renewal_invoice'
require_relative 'paid_coverage'

# Strict renewal-only shape. PaidCoverage also supports initial purchases and
# upgrades, so its verified result alone is insufficient for this transition.
class Toybaco::Growth::OrdinaryRenewalInvoice
  Invalid = Toybaco::Growth::PostingPreparationRecord::Invalid

  def initialize(binding, period)
    @binding = binding
    @period = period
  end

  def validate!(invoice, paid:)
    raise Invalid unless identity?(invoice) && Toybaco::Growth::RenewalInvoice.new(invoice, @binding.fetch('contract'), failure).valid?
    raise Invalid unless invoice['billing_reason'] == 'subscription_cycle' && invoice['collection_method'] == 'charge_automatically'
    raise Invalid unless amounts?(invoice, paid)

    invoice
  end

  def previous!(invoice, coverage)
    period = coverage.slice('invoice_id', 'term_start', 'term_end')
    verifier = self.class.new(@binding, period)
    raise Invalid unless %w[subscription_create subscription_cycle].include?(invoice['billing_reason'])

    verifier.validate!(invoice.merge('billing_reason' => 'subscription_cycle'), paid: true)
    raise Invalid unless invoice.dig('status_transitions', 'paid_at') == coverage['paid_at']
  end

  private

  def failure
    @period.merge('subscription_id' => @binding.fetch('subscription_id'))
  end

  def identity?(invoice)
    invoice.is_a?(Hash) && invoice['id'] == @period['invoice_id'] && invoice['customer'] == @binding['customer_id'] &&
      invoice['livemode'] == (@binding['mode'] == 'live') && invoice['currency'] == 'jpy' &&
      (invoice['subscription'] || invoice.dig('parent', 'subscription_details', 'subscription')) == @binding['subscription_id']
  end

  def amounts?(invoice, paid)
    amount = invoice['amount_due']
    return false unless amount.is_a?(Integer) && amount.positive? && invoice['subtotal'].is_a?(Integer) && amount >= invoice['subtotal']

    expected = paid ? ['paid', 0, amount] : ['open', amount, 0]
    invoice.values_at('status', 'amount_remaining', 'amount_paid') == expected
  end
end
