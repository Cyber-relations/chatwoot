# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/billing_receipt'
require_relative '../../../lib/toybaco/growth/opening_receipt'

class Toybaco::BillingWebhooksController < Toybaco::GrowthPaymentWebhooksController
  def create
    return head :service_unavailable unless Toybaco::Growth::BillingReceipt.enabled? || Toybaco::Growth::OpeningReceipt.enabled?

    raw = request.body.read(Toybaco::Growth::PaymentSignature::MAX_BYTES + 1)
    environment = { 'TOYBACO_STRIPE_PACK_WEBHOOK_SECRET' => ENV.fetch('TOYBACO_STRIPE_BILLING_WEBHOOK_SECRET', nil) }
    event = Toybaco::Growth::PaymentSignature.verify!(raw, request.headers['Stripe-Signature'], environment: environment)
    attributes = Toybaco::Growth::BillingSnapshot.new(event).read
    return head :bad_request unless attributes

    return head :service_unavailable unless enabled_for?(attributes)

    receipt = Toybaco::Growth::BillingReceipt.accept!(attributes)
    Toybaco::Growth::BillingReceipt.enqueue(receipt)
    render json: { status: 'accepted', event_id: receipt.event_id, mode: receipt.mode, receipt_id: receipt.id }
  rescue Toybaco::Growth::PaymentSignature::Invalid, Toybaco::Growth::BillingReceipt::Conflict
    head :bad_request
  rescue Toybaco::Growth::PaymentSignature::Unconfigured, ActiveRecord::ActiveRecordError
    head :service_unavailable
  end

  private

  def enabled_for?(attributes)
    attributes[:action] == 'opening_checkout' ? Toybaco::Growth::OpeningReceipt.enabled? : Toybaco::Growth::BillingReceipt.enabled?
  end
end
