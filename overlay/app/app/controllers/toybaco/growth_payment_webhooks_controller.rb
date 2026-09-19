# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/payment_receipt'
require_relative '../../../lib/toybaco/growth/payment_dispatch'

# Stripe authenticates with the endpoint signature; customer sessions do not apply.
class Toybaco::GrowthPaymentWebhooksController < ActionController::Base # rubocop:disable Rails/ApplicationController
  skip_forgery_protection

  def create
    raw = request.body.read(Toybaco::Growth::PaymentSignature::MAX_BYTES + 1)
    event = Toybaco::Growth::PaymentSignature.verify!(raw, request.headers['Stripe-Signature'])
    snapshot = Toybaco::Growth::PaymentSnapshot.new(event).read
    receipt = Toybaco::Growth::PaymentReceipt.accept!(snapshot)
    Toybaco::Growth::PaymentDispatch.enqueue(receipt) if receipt
    head :ok
  rescue Toybaco::Growth::PaymentSignature::Invalid, Toybaco::Growth::PaymentReceipt::Conflict
    head :bad_request
  rescue Toybaco::Growth::PaymentSignature::Unconfigured, ActiveRecord::ActiveRecordError
    head :service_unavailable
  end
end
