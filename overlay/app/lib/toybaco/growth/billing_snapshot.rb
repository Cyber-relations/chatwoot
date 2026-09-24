# frozen_string_literal: true

require_relative 'payment_snapshot'
require_relative 'renewal_invoice_snapshot'

class Toybaco::Growth::BillingSnapshot < Toybaco::Growth::PaymentSnapshot
  SUBSCRIPTIONS = %w[customer.subscription.updated customer.subscription.deleted].freeze
  INVOICES = %w[invoice.paid invoice.payment_failed].freeze

  def read
    verify_event!
    object = @event.dig('data', 'object')
    raise Toybaco::Growth::PaymentSignature::Invalid unless object.is_a?(Hash)

    attributes = extract(object)
    attributes&.merge(mode: @event['livemode'] ? 'live' : 'test')
  end

  private

  def extract(object)
    return checkout(object) if @event['type'] == 'checkout.session.completed'
    return subscription(object['id']) if SUBSCRIPTIONS.include?(@event['type']) && object['object'] == 'subscription'

    invoice(object) if INVOICES.include?(@event['type'])
  end

  def invoice(object)
    return unless object['object'] == 'invoice'

    id = object['subscription'] || object.dig('parent', 'subscription_details', 'subscription')
    return unless id

    fields = Toybaco::Growth::RenewalInvoiceSnapshot.read(object, @event['type'])
    fields ? build('subscription_notice', id, fields) : subscription(id)
  end

  def checkout(object)
    return unless object['mode'] == 'subscription'

    metadata = object['metadata']
    return unless metadata.is_a?(Hash)

    existing = metadata.key?('toybaco_existing_account_id') || metadata.key?('toybaco_purchase_nonce')
    return unless existing || opening_metadata?(metadata)

    verify_checkout!(object)

    build(existing ? 'growth_checkout' : 'opening_checkout', object['id'], object.slice('id', 'object'))
  end

  def verify_checkout!(object)
    raise Toybaco::Growth::PaymentSignature::Invalid unless object['object'] == 'checkout.session' &&
                                                            object['id'].to_s.match?(/\Acs_(?:test_|live_)?[A-Za-z0-9]{1,200}\z/)
  end

  def opening_metadata?(metadata)
    keys = %w[toybaco_plan toybaco_plan_version toybaco_cycle toybaco_reference_price_id]
    keys.all? { |key| metadata[key].is_a?(String) && metadata[key].present? }
  end

  def subscription(id)
    raise Toybaco::Growth::PaymentSignature::Invalid unless id.is_a?(String) && id.match?(/\Asub_[A-Za-z0-9]{1,200}\z/)

    build('subscription_notice', id, { 'subscription' => id })
  end
end
