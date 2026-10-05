# frozen_string_literal: true

require_relative 'renewal_ingress_verification'
require_relative 'scheduled_downgrade'
require_relative 'renewal_dispatch_continuation'
require_relative 'renewal_coordinator'
require_relative 'renewal_coordinator_settlement'
require_relative 'period_end_free_return'

class Toybaco::Growth::RenewalDispatchWork
  Attention = Class.new(StandardError)
  Record = Toybaco::Growth::PostingPreparationRecord
  # The failure path returns to Free under the rollout flags and hold error rules of the period-end return.
  FREE_FLAGS = Toybaco::Growth::PeriodEndCancel::FLAGS
  HOLD_ATTENTION = Toybaco::Growth::PeriodEndFreeReturn::ATTENTION

  def initialize(row, client:, environment:, clock:, **options)
    @row = row
    @client = client
    @environment = environment
    @clock = clock
    @options = options
    @connector = @options.delete(:connector)
  end

  def call
    raise Record::Invalid if Account.connection.transaction_open?

    load_source!
    parent = Toybaco::GrowthRenewalCoordinator.find_by(renewal_operation_id: @operation.id)
    return recover_settlement!(parent) if parent

    advance_invoice!
  end

  private

  def recover_settlement!(parent)
    raise Attention, 'stop_attention' if parent.phase == 'attention'
    return due! if %w[prepared waiting].include?(parent.phase)

    settle!
  end

  def advance_invoice!
    subscription = @client.retrieve_subscription(@operation.subscription_id)
    invoice = current_invoice(subscription)
    raise Attention, 'invoice_changed' unless invoice.is_a?(Hash) && invoice['id'] == @operation.invoice_id
    return continue!('renewal_paid') if invoice['status'] == 'paid'
    raise Attention, 'invoice_unresolved' unless invoice['status'] == 'open'
    raise Attention, 'first_failure_missing' unless @operation.due_at
    return due! if @clock.call >= @operation.due_at

    continue!('renewal_grace')
  end

  def current_invoice(subscription)
    invoice = subscription['latest_invoice']
    invoice.is_a?(String) ? @client.retrieve_invoice(invoice) : invoice
  end

  def load_source!
    @operation = Toybaco::RenewalOperation.find(@row.renewal_operation_id)
    fact = Toybaco::RenewalInvoiceFact.find(@row.requested_fact_id)
    event = Toybaco::BillingEvent.find(fact.billing_event_id)
    raise Record::Invalid unless fact.renewal_operation_id == @operation.id && @environment['TOYBACO_STRIPE_MODE'] == @operation.mode

    verify_event!(fact, event)
    return if Toybaco::GrowthRenewalCoordinator.exists?(renewal_operation_id: @operation.id)

    verify_ordinary!(event)
    load_owner!
  end

  def verify_event!(fact, event)
    Toybaco::Growth::BillingReceipt.verify!(event)
    Toybaco::Growth::RenewalIngress.verify!(fact, event)
    return unless Toybaco::Growth::ScheduledDowngrade.applicable?(event)

    Toybaco::Growth::ScheduledDowngrade.new(event, client: @client, now: @clock.call, environment: @environment).record!
    raise Attention, 'scheduled_posting_or_free_pending'
  end

  def verify_ordinary!(event)
    Toybaco::Growth::RenewalIngressVerification.new(event, client: @client, now: @clock.call).record!
    @operation.reload
    raise Attention, 'ordinary_evidence_unavailable' unless %w[observed_failure resolved_observation].include?(@operation.state)
  end

  def load_owner!
    @account = Account.find(@operation.account_id)
    owner = Toybaco::Entitlements.attributes(@account)['toybaco_billing_owner_user_id']
    raise Record::Invalid unless owner.is_a?(Integer) && owner.positive?

    @owner = User.find(owner)
  end

  def continue!(kind)
    service = Toybaco::Growth::RenewalDispatchContinuation.new(@account, @owner, client: @client, environment: @environment,
                                                                                 clock: @clock, **@options, &@connector)
    service.call(@row, @operation, kind: kind)
  end

  def due!
    result = Toybaco::Growth::RenewalCoordinator.new(@operation.id, client: @client, environment: @environment, clock: @clock).call
    raise Attention, 'stop_attention' if result['phase'] == 'attention'
    return 'due_waiting' unless result['phase'] == 'stop_recorded'

    settle!
  end

  def settle!
    service = Toybaco::Growth::RenewalCoordinatorSettlement.new(@operation.id, client: @client, environment: @environment, clock: @clock)
    result = service.call
    raise Attention, 'payment_review' if result['phase'] == 'payment_review'
    return free_completed! if result['phase'] == 'free_completed'
    return 'due_waiting' unless result['phase'] == 'provider_closed'
    return 'provider_closed' unless FREE_FLAGS.all? { |flag| @environment[flag] == 'true' }

    hold!
    result = service.complete_free!
    raise Record::Invalid unless result['phase'] == 'free_completed'

    free_completed!
  end

  # The Free write has committed (this work runs outside Account transactions). The Free transition notice is
  # enqueued after it, also when a rerun finds the transition complete; Growth::RenewalFreeNotice sends it at
  # most once per transition. A queue failure (an error, or an enqueue the adapter refused) never changes the result.
  def free_completed!
    queued = Toybaco::GrowthRenewalFreeNoticeJob.perform_later(@operation.account_id)
    raise ActiveJob::EnqueueError, 'free transition notice not enqueued' unless queued

    'free_completed'
  rescue StandardError => e
    Rails.logger.warn("toybaco_renewal_free_notice_unqueued account=#{@operation.account_id} class=#{e.class.name}")
    'free_completed'
  end

  # Stripe is closed. The posting hold, then the inbox hold of this transition, in the period-end order;
  # both are idempotent for the same transition. A busy fence or lock, the provider or the Postiz
  # transport leaves the row pending until its deadline; a changed binding or an invalid record stops it.
  def hold!
    account = @account || Account.find(@operation.account_id)
    Toybaco::Growth::PostingRetention.new(account, environment: @environment, clock: @clock).call
    Toybaco::Growth::InboxRetention.new(account, environment: @environment, clock: @clock).call
  rescue *HOLD_ATTENTION
    raise Attention, 'hold_attention'
  end
end
