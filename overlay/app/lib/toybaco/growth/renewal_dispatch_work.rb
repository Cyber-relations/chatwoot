# frozen_string_literal: true

require_relative 'renewal_ingress_verification'
require_relative 'scheduled_downgrade'
require_relative 'renewal_dispatch_continuation'
require_relative 'renewal_coordinator'
require_relative 'renewal_coordinator_settlement'

class Toybaco::Growth::RenewalDispatchWork
  Attention = Class.new(StandardError)
  Record = Toybaco::Growth::PostingPreparationRecord

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
    return 'free_completed' if result['phase'] == 'free_completed'
    return 'due_waiting' unless result['phase'] == 'provider_closed'
    return 'provider_closed' unless @environment['TOYBACO_GROWTH_FREE_RETURN_ENABLED'] == 'true'

    result = service.complete_free!
    raise Record::Invalid unless result['phase'] == 'free_completed'

    'free_completed'
  end
end
