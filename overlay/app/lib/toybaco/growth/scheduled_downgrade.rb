# frozen_string_literal: true

require_relative '../checkout/scheduled_downgrade_evidence'
require_relative '../checkout/plan_change_lock'
require_relative 'scheduled_downgrade_context'
require_relative 'scheduled_downgrade_invoice'
require_relative 'scheduled_downgrade_grace'
require_relative 'scheduled_downgrade_persistence'

# Signed durable admission -> read-only Stripe verification -> immutable cause.
# No provider mutation, schedule release, hold or Free coordinator is invoked.
class Toybaco::Growth::ScheduledDowngrade
  include Toybaco::Growth::ScheduledDowngradePersistence
  Context = Toybaco::Growth::ScheduledDowngradeContext
  Record = Toybaco::Growth::PostingPreparationRecord
  Model = Toybaco::GrowthScheduledDowngrade
  FLAG = 'TOYBACO_SCHEDULED_DOWNGRADE_GRACE_ENABLED'

  def self.applicable?(event)
    fact = Toybaco::RenewalInvoiceFact.find_by(billing_event_id: event.id)
    return false unless fact
    return true if Model.exists?(renewal_operation_id: fact.renewal_operation_id)

    accounts = Account.where("internal_attributes ->> 'toybaco_subscription_id' = ?", fact.subscription_id).limit(2).to_a
    return false unless event.snapshot['type'] == 'invoice.payment_failed'

    return false unless accounts.one?

    reserved_source?(accounts.first)
  end

  def self.reserved_source?(account)
    contract = Toybaco::Entitlements.contract_for(account)
    return false unless contract['legacy'] == false && contract.dig('entitlements', 'ai_meter') == Toybaco::GrowthTerms::METER

    account.internal_attributes.dig('toybaco_plan_change', 'status') == 'reserved' &&
      account.internal_attributes.dig('toybaco_plan_change', 'quote', 'policy', 'kind') == 'downgrade'
  end

  def initialize(event, client:, now: Time.now.utc, environment: ENV)
    @event = event
    @client = client
    @now = now
    @environment = environment
  end

  def record!
    raise Record::Invalid if Account.connection.transaction_open?

    Toybaco::Growth::BillingReceipt.verify!(@event)
    fact = Toybaco::Growth::RenewalIngress.verify!(Toybaco::RenewalInvoiceFact.find_by(billing_event_id: @event.id), @event)
    @operation_id = fact.renewal_operation_id
    accounts = Account.where("internal_attributes ->> 'toybaco_subscription_id' = ?", fact.subscription_id).limit(2).to_a
    raise Record::Invalid unless accounts.one?

    @account = accounts.first
    Toybaco::Checkout::PlanChangeLock.call(@account) { verify_and_save }
  end

  private

  def verify_and_save
    previous = locked { Model.find_by(renewal_operation_id: @operation_id) }
    return 'scheduled_downgrade_paid_history' if previous&.recovery && paid_history?(previous)
    raise Record::Invalid unless previous || @environment[FLAG] == 'true'

    source = locked { capture }.deep_dup
    reservation, evidence, paid = verify_provider(source)

    locked do
      raise Record::Invalid unless capture == source

      row = Model.find_by(renewal_operation_id: @operation_id)
      persist!(row, source, reservation, evidence, paid)
    end
  end

  def verify_provider(source)
    subscription = @client.retrieve_subscription(source.dig('binding', 'subscription_id'))
    checker = Toybaco::Checkout::ScheduledDowngradeEvidence.new(account: @account, client: @client, environment: @environment)
    inputs = { source: source.dig('binding', 'contract'), coverage: source.dig('binding', 'coverage') }
    reservation = checker.verify!(source.fetch('reservation'), subscription, **inputs)
    paid = subscription.dig('latest_invoice', 'status') == 'paid'
    kind = paid ? 'renewal_paid' : 'renewal_grace'
    evidence = Toybaco::Growth::ScheduledDowngradeInvoice.new(source, reservation: reservation, client: @client, now: @now)
                                                         .verify!(kind: kind, failure: source.fetch('failure'))
    raise Record::Invalid unless evidence['subscription_hash'] == Toybaco::Growth::ScheduledDowngradeInvoice.subscription_hash(subscription)

    [reservation, evidence, paid]
  end

  def paid_history?(row)
    locked do
      Toybaco::Growth::ScheduledDowngradeGrace.validate!(row.reload, now: @now)
      attrs = Toybaco::Entitlements.attributes(@account)
      raise Record::Invalid unless attrs['toybaco_subscription_id'] == row.receipt.dig('binding', 'subscription_id') &&
                                   attrs['toybaco_stripe_customer_id'] == row.receipt.dig('binding', 'customer_id') &&
                                   @event.mode == row.receipt.dig('binding', 'mode')

      Toybaco::Entitlements.contract_for(@account) == row.receipt.dig('reservation', 'target') &&
        attrs[Toybaco::Growth::PaidPeriod::KEY]&.except('current_period_start', 'current_base_limit') == row.recovery['coverage']
    end
  end

  def capture
    operation = Toybaco::RenewalOperation.lock('FOR UPDATE NOWAIT').find(@operation_id)
    Context.capture(@account, operation, @now, @environment)
  end

  def locked
    Account.uncached do
      Account.transaction do
        @account = Toybaco::Growth::PostingPrincipal.locked_account!(@account.id)
        yield
      end
    end
  end
end
