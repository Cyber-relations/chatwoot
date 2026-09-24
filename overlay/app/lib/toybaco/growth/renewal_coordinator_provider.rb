# frozen_string_literal: true

require_relative 'renewal_settlement'
require_relative 'ordinary_renewal_invoice'

# Reuses the existing exact invoice/payment/debt checks, but never its call:
# every provider operation here requires an outer Account commit boundary.
class Toybaco::Growth::RenewalCoordinatorProvider < Toybaco::Growth::RenewalSettlement
  def initialize(account, receipt, client:, environment:, now:)
    super(account, client: client, environment: environment, now: now)
    @source = receipt.fetch('source')
  end

  def read!
    assert_commit_boundary!
    raise Unresolved unless due? && billing_operations_finished?

    sub = checked_subscription!
    invoice = checked_invoice!
    return 'payment_review' if invoice['status'] == 'paid'

    unpaid_invoice!(invoice)
    provider_state(sub, invoice)
  end

  def void!
    assert_commit_boundary!
    raise Unresolved unless due?

    close_invoice!(invoice!)
  rescue Toybaco::Checkout::Error, Timeout::Error, IOError
    nil
  end

  def cancel!
    assert_commit_boundary!
    raise Unresolved unless due?

    cancel_subscription!
  rescue Toybaco::Checkout::Error, Timeout::Error, IOError
    nil
  end

  private

  def checked_subscription!
    sub = subscription!
    raise Unresolved unless sub.values_at('pause_collection', 'pending_update', 'schedule', 'cancel_at_period_end') == [nil, nil, nil, false]
    raise Unresolved unless sub.dig('metadata', 'toybaco_purchase_nonce') == @source.dig('binding', 'purchase_nonce')

    sub
  end

  def checked_invoice!
    invoice = invoice!
    previous = @source.dig('binding', 'coverage')
    Toybaco::Growth::OrdinaryRenewalInvoice.new(@source.fetch('binding'), previous)
                                           .previous!(@client.retrieve_invoice(previous.fetch('invoice_id')), previous)
    raise Unresolved unless safe_customer?

    invoice
  end

  def provider_state(sub, invoice)
    return 'provider_closed' if sub['status'] == 'canceled' && invoice['status'] == 'void'
    raise Unresolved if sub['status'] == 'canceled'

    invoice['status'] == 'void' ? 'invoice_voided' : 'prepared'
  end

  def unpaid_invoice!(invoice)
    raise Unresolved unless %w[open void].include?(invoice['status']) && unpaid?(invoice)
    raise Unresolved unless Toybaco::Growth::RenewalPayments.new(@client, invoice).idle?

    unpaid_amounts!(invoice)
  end

  def unpaid_amounts!(invoice)
    raise Unresolved unless invoice['amount_due'].is_a?(Integer) && invoice['amount_due'].positive?
    # Voiding an unpaid invoice preserves its amount fields; status closes collection.
    raise Unresolved unless invoice['amount_remaining'] == invoice['amount_due']
  end
end
