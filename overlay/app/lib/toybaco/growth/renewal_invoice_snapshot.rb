# frozen_string_literal: true

module Toybaco::Growth::RenewalInvoiceSnapshot
  module_function

  def read(object, event_type)
    return unless object['billing_reason'] == 'subscription_cycle'

    subscription = object['subscription'] || object.dig('parent', 'subscription_details', 'subscription')
    fields = object.slice('id', 'object', 'customer', 'billing_reason', 'attempt_count').merge('subscription' => subscription)
    valid = identity?(fields) && fields['attempt_count'].is_a?(Integer) &&
            fields['attempt_count'] >= (event_type == 'invoice.payment_failed' ? 1 : 0)
    raise Toybaco::Growth::PaymentSignature::Invalid unless valid

    fields
  end

  def identity?(fields)
    fields['object'] == 'invoice' && identifier?(fields['id'], 'in') && identifier?(fields['subscription'], 'sub') &&
      identifier?(fields['customer'], 'cus')
  end

  def identifier?(value, prefix)
    value.is_a?(String) && value.match?(/\A#{prefix}_[A-Za-z0-9]{1,200}\z/)
  end
end
