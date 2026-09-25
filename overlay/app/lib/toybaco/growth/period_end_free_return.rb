# frozen_string_literal: true

require_relative 'free_return'
require_relative 'period_end_cancel'
require_relative 'posting_retention'
require_relative 'retention_inventory'

# Returns a paid growth store to Free after Stripe ended its subscription at the
# period end. It runs after the Sync committed and outside any transaction: the holds
# need HTTP and the exclusive inbox fence. The store is never suspended, so its
# posting membership stays; the failure path's atomic Free write replaces the contract.
class Toybaco::Growth::PeriodEndFreeReturn < Toybaco::Growth::FreeReturn
  FLAGS = Toybaco::Growth::PeriodEndCancel::FLAGS
  CAUSE = 'period_end_cancel'
  SUBSCRIPTION = /\Asub_[A-Za-z0-9]+\z/
  CUSTOMER = /\Acus_[A-Za-z0-9]+\z/
  Rules = Toybaco::Growth::PeriodEndCancel
  Changed = Toybaco::Growth::RenewalTransition::Changed
  # Retried by the reconciliation request: busy writers, locks, provider or Postiz transport.
  PENDING = [Toybaco::Growth::InboxRetention::Busy, Toybaco::Checkout::Error, Toybaco::Growth::RetentionProtocol::Invalid,
             ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked, Timeout::Error].freeze
  # A changed binding or an invalid record waits for an operator.
  ATTENTION = [Changed, Toybaco::Growth::FreeReturnRecord::Invalid, Toybaco::Growth::InboxRetention::Invalid,
               Toybaco::Growth::InboxReleaseRecord::Invalid, Toybaco::Growth::RetentionPlan::Invalid, Toybaco::PlanCatalog::Invalid].freeze

  def self.applicable?(account)
    Rules.account?(account, Toybaco::Entitlements.attributes(account))
  end

  def call
    return 'attention' unless FLAGS.all? { |flag| @environment[flag] == 'true' }

    Toybaco::Checkout::PlanChangeLock.call(@account) { return_to_free }
  rescue *PENDING
    'free_pending'
  rescue *ATTENTION
    'attention'
  end

  private

  def return_to_free
    raise Toybaco::Growth::FreeReturnRecord::Invalid if @account.class.connection.transaction_open?
    return 'free_completed' if @account.with_lock { returned? }

    cancel = provider_cancel!
    @account.with_lock { journal!(cancel) }
    Toybaco::Growth::PostingRetention.new(@account, environment: @environment, clock: @clock).call
    Toybaco::Growth::InboxRetention.new(@account, environment: @environment, clock: @clock).call
    Toybaco::Growth::InboxRetention.with_fence(@account.id, exclusive: true) { @account.with_lock { complete! } }
    'free_completed'
  end

  # Only this subscription's completed return short-circuits. A store that bought
  # again after an earlier return keeps that receipt as history and returns anew.
  def returned?
    completed_receipt && Toybaco::Entitlements.attributes(@account)['toybaco_subscription_id'].nil?
  end

  # A fresh read of the same subscription, customer and Stripe mode, checked with the
  # rules of the Sync decision before anything is written.
  def provider_cancel!
    id, customer = Toybaco::Entitlements.attributes(@account).values_at('toybaco_subscription_id', 'toybaco_stripe_customer_id')
    raise Changed unless id.to_s.match?(SUBSCRIPTION) && customer.to_s.match?(CUSTOMER)

    subscription = @client.retrieve_subscription(id)
    raise Changed unless same_subscription?(subscription, id, customer) && Rules.subscription?(subscription)

    Rules.evidence(subscription)
  end

  def same_subscription?(subscription, id, customer)
    subscription.is_a?(Hash) && subscription['id'] == id && subscription['customer'] == customer &&
      %w[test live].include?(mode) && subscription['livemode'] == (mode == 'live')
  end

  def mode
    @environment['TOYBACO_STRIPE_MODE']
  end

  # The stored side and busy work are checked before the first write, so a deferred
  # return leaves nothing behind. Stripe already closed the subscription.
  def journal!(cancel)
    @now = @clock.call
    raise Changed unless self.class.applicable?(@account)

    idle!
    transition = Toybaco::Growth::RenewalTransition.new(@account, now: @now, mode: mode, cancel: cancel)
    transition.prepare!(inventory: @inventory || Toybaco::Growth::RetentionInventory.new(@account))
    transition.advance!('provider_closed')
  end

  # An unfinished posting execution or automatic request, or a live automatic lease.
  def idle!
    unresolved = Toybaco::GrowthPostingExecution.where(account_id: @account.id).where.not(state: %w[completed cancelled]).exists? ||
                 Toybaco::GrowthAutoRequest.unresolved.exists?(account_id: @account.id)
    raise Toybaco::Growth::InboxRetention::Busy if unresolved

    ensure_idle!
  end

  def settlement_evidence(attrs)
    journal = attrs.fetch(Toybaco::Growth::RenewalTransition::KEY)
    { 'state' => 'closed', 'cause' => CAUSE, 'subscription_id' => journal.dig('binding', 'subscription_id'),
      'ended_at' => journal.dig('binding', 'cancel', 'ended_at'), 'observed_at' => journal.fetch('observed_at') }
  end
end
