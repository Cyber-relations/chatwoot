# frozen_string_literal: true

require 'delegate'

class Toybaco::Growth::BillingModeClient < SimpleDelegator
  def initialize(client, mode)
    super(client)
    @mode = mode
  end

  def retrieve_checkout_session(id)
    verify!(__getobj__.retrieve_checkout_session(id), id)
  end

  def retrieve_subscription(id)
    verify!(__getobj__.retrieve_subscription(id), id)
  end

  def verify!(object, id)
    raise Toybaco::Growth::PaymentSignature::Invalid unless object.is_a?(Hash) && object['id'] == id && object['livemode'] == (@mode == 'live')

    object
  end
end
