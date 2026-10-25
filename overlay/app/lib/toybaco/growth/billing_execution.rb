# frozen_string_literal: true

require_relative 'payment_execution'
require_relative 'purchase_fulfillment'
require_relative 'billing_subscription'
require_relative 'billing_receipt'
require_relative 'billing_mode_client'
require_relative 'opening_fulfillment'
require_relative 'opening_operations'
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
    expired = false
    token = @event.with_lock do
      next unless @event.state == 'queued' || Toybaco::Growth::PaymentDispatch.due?(@event, @now)

      if @event.deadline_at <= @now || @event.attempts >= @event.attempt_limit
        @event.update!(state: 'attention', result: 'retry_limit', lease_token: nil, lease_expires_at: nil)
        Rails.logger.error('TOYBACO_BILLING_ATTENTION retry_limit=true')
        Rails.logger.error("TOYBACO_BILLING_ATTENTION_NEW receipt=#{@event.id} result=retry_limit")
        expired = true
        next
      end
      super
    end
    tell_operations('retry_limit') if expired
    token
  end

  def fail!(result, final:)
    raise 'billing receipt could not be claimed' unless @token

    state = final || @event.attempts >= @event.attempt_limit ? 'attention' : 'pending'
    finish!(state, result)
    return unless state == 'attention'

    Rails.logger.error("TOYBACO_BILLING_ATTENTION receipt=#{@event.id}")
    tell_operations(result) if @event.state == 'attention'
  end

  # attention に決まる時は、TOYBACO_BILLING_ATTENTION_NEW を commit の前(行 lock の中、update! の直後)に出す。commit の後に出すと、
  # その間に worker が止まった時に行もメールも出ず、行は再び claim されず、毎分の sweep の行は alarm に当たらないため、日次ダイジェストまで
  # 気付かない。commit が失敗した時は alarm が偽陽性になるが、取りこぼしよりよい。行を書かなかった時(lease を失った時)は出さない。
  def finish!(state, result)
    return super unless state == 'attention'

    Toybaco::BillingEvent.transaction do
      written = super
      Rails.logger.error("TOYBACO_BILLING_ATTENTION_NEW receipt=#{@event.id} result=#{result}") if written && @event.state == 'attention'
      written
    end
  end

  # 受付が attention になる 2 か所(claim の期限切れと fail!)だけが TOYBACO_BILLING_ATTENTION_NEW を 1 回出し、billing-attention の
  # alarm はこの行を数える(毎分の BillingReceipt.sweep が残る間ずっと出す pending_receipts=true の行は数えない)。
  # 開通の受付だけ、店舗を作れなかったことを運営へメールでも知らせる(alarm の通知には受付の中身が載らないため)。
  def tell_operations(result)
    Toybaco::Growth::OpeningOperations.failed!(@event, result) if @event.action == 'opening_checkout'
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
