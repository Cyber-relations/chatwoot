# frozen_string_literal: true

require_relative 'payment_execution'
require_relative 'purchase_fulfillment'
require_relative 'billing_subscription'
require_relative 'billing_receipt'
require_relative 'billing_mode_client'
require_relative 'opening_fulfillment'
require_relative 'renewal_ingress_verification'
require_relative 'renewal_dispatch_queue'

class Toybaco::Growth::BillingExecution < Toybaco::Growth::PaymentExecution
  class Pending < StandardError; end

  def call
    raise Toybaco::SubscriptionReconciliation::Invalid if Account.connection.transaction_open?

    super
  end

  private

  def claim
    @event.with_lock do
      next unless @event.state == 'queued' || Toybaco::Growth::PaymentDispatch.due?(@event, @now)

      if @event.deadline_at <= @now || @event.attempts >= @event.attempt_limit
        @event.update!(state: 'attention', result: 'retry_limit', lease_token: nil, lease_expires_at: nil)
        Rails.logger.error('TOYBACO_BILLING_ATTENTION retry_limit=true')
        next
      end
      super
    end
  end

  def fail!(result, final:)
    raise 'billing receipt could not be claimed' unless @token

    state = final || @event.attempts >= @event.attempt_limit ? 'attention' : 'pending'
    finish!(state, result)
    Rails.logger.error("TOYBACO_BILLING_ATTENTION receipt=#{@event.id}") if state == 'attention'
  end

  def verify_renewal!
    client = @client || Toybaco::Checkout::Client.new(ENV.fetch('TOYBACO_STRIPE_KEY', ''))
    require_relative 'scheduled_downgrade'
    if Toybaco::Growth::ScheduledDowngrade.applicable?(@event)
      return Toybaco::Growth::ScheduledDowngrade.new(@event, client: client, now: @now).record!
    end

    Toybaco::Growth::RenewalIngressVerification.new(@event, client: client, now: @now).record!
  end

  def accept_subscription!
    dispatcher = Toybaco::Growth::RenewalDispatch.for_event(@event)
    if dispatcher
      Toybaco::Growth::RenewalDispatchQueue.enqueue(dispatcher, now: @now)
      return 'renewal_dispatch_accepted'
    end

    verify_renewal! if Toybaco::Growth::RenewalIngress.invoice?(@event.snapshot)
    Toybaco::Growth::BillingSubscription.accept!(@event, now: @now)
    'subscription_accepted'
  end

  def reconcile
    Toybaco::Growth::BillingReceipt.verify!(@event)
    raise Toybaco::Growth::PaymentSignature::Invalid unless ENV['TOYBACO_STRIPE_MODE'] == @event.mode

    return accept_subscription! if @event.action == 'subscription_notice'

    client = @client || Toybaco::Checkout::Client.new(ENV.fetch('TOYBACO_STRIPE_KEY', ''))
    return Toybaco::Growth::OpeningFulfillment.new(@event, client: client).call if @event.action == 'opening_checkout'

    raise Toybaco::Growth::PaymentSignature::Invalid unless @event.action == 'growth_checkout'

    checked = Toybaco::Growth::BillingModeClient.new(client, @event.mode)
    result = Toybaco::Growth::PurchaseFulfillment.new(client: checked).complete!(@event.reference_id)
    raise Pending unless result == 'complete'

    'checkout_complete'
  end
end
