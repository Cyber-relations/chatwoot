# frozen_string_literal: true

require 'delegate'
require_relative '../growth/period_end_free_return'

module Toybaco::SubscriptionReconciliation::Processing
  FREE_RETURN_RESULTS = { nil => 'applied', 'free_completed' => 'applied', 'free_pending' => 'free_return_pending' }.freeze
  # What the suspension Sync must leave as it found them: the return's journal, the store's
  # subscription, the holds and the pointer of the Free record.
  RETURN_KEYS = [Toybaco::Growth::RenewalTransition::KEY, 'toybaco_subscription_id', Toybaco::Growth::PostingRetention::KEY,
                 Toybaco::Growth::InboxRetention::KEY, Toybaco::Growth::FreeReturnRecord::KEY].freeze

  private

  def reconcile
    return 'attention' unless @environment['TOYBACO_STRIPE_MODE'] == @record.mode

    account = bound_account
    return 'superseded' if account == :superseded
    raise Toybaco::SubscriptionReconciliation::NotProvisioned unless account

    checked = mode_client
    # This method retains the existing subscription lock, complete parent /
    # child transaction and current-subscription checks. The request claim
    # was committed separately before any Stripe read or business update.
    outcome = Toybaco::StoreFulfillment.synchronize(account, subscription_id: @record.subscription_id, client: checked,
                                                             guard: renewal_guard, environment: @environment, free_return: true)
    return period_end_free_return(account, checked) if outcome == 'applied'

    %w[payment_pending renewal_pending].include?(outcome) ? outcome : 'attention'
  end

  # A paid growth store that the Sync kept active at its ended period-end cancellation
  # returns to Free here, after that transaction committed: the holds need HTTP and
  # fences. Only a fixed test time is passed; otherwise each step reads the real clock.
  def period_end_free_return(account, client)
    account.reload
    finalizer = Toybaco::Growth::PeriodEndFreeReturn
    return 'applied' unless finalizer.applicable?(account)

    @returning = [account, client]
    FREE_RETURN_RESULTS.fetch(finalizer.new(account, client: client, environment: @environment, now: @fixed_now).call, 'attention')
  end

  # The Sync skips the suspension only while the Free return is in progress. A run that
  # leaves the request in attention after the return (its own attention, or the retries
  # and deadline of free_return_pending spent) runs the same Sync once more without the
  # opt-in, which takes the existing suspension (fail-closed). It writes no journal, hold
  # or Free record; a re-armed return continues from the suspension and lifts it. This is
  # the fast path: when it fails or never runs, the sweep retries it from durable facts.
  def suspend_after_attention
    return unless @record.reload.state == 'attention'

    account, client = @returning || ((@expired_return || @suspension_due) && expired_target)
    suspend_unchanged(account.reload, client) if account
  rescue Toybaco::SubscriptionReconciliation::SuspensionChanged
    # Rolled back whole. A re-armed request runs again; otherwise the request stays in
    # attention and the sweep keeps retrying.
    Rails.logger.error('TOYBACO_SUBSCRIPTION_SYNC_SUSPENSION_INVARIANT')
    nil
  rescue StandardError => e
    # SubscriptionReconciliation.suspension_due? keeps the sweep retrying every minute.
    Rails.logger.error("TOYBACO_SUBSCRIPTION_SYNC_SUSPENSION_RETRY #{e.class}")
    nil
  end

  # The suspension Sync may only suspend. Its facts are read under its lock before any
  # write (the guard) and again before its commit (the block, same transaction): a Sync
  # that changed the journal, the store's subscription, a hold or the pointer, wrote a
  # Free contract or a Free record, or turned the paid contract into one that
  # PeriodEndCancel.paid_contract? refuses (a re-armed return could not continue from
  # it), is rolled back whole. The store then stays active under its unfinished journal,
  # which keeps the suspension due for the sweep. Behind the renewal barrier the
  # suspension-only guard decides (Execution#suspension_guard); a Sync that the guard kept
  # waiting (renewal_pending) wrote no suspension and is logged for the sweep's retry.
  # The guard first locks the request row and reads it again, right after the Stripe read
  # and before any write: the store's update disables Postiz in Postiz's own database
  # (PostizSync.disable_account!, which also revokes the organization's API key), which no
  # rollback here restores. The lock holds until the commit, so a re-arm (a notification's
  # refresh_request!, rearm_waiting!) either came first, leaving another state or revision
  # than at suspend_after_attention's reload, and rolls the suspension back before any
  # write, or waits and re-arms the suspended store afterwards. The row is locked after the
  # account rows, and no path that locks it waits for an account row while holding it.
  def suspend_unchanged(account, client)
    before = nil
    decide = @behind_barrier ? suspension_guard : renewal_guard
    guard = lambda do |locked, subscription|
      raise Toybaco::SubscriptionReconciliation::SuspensionChanged unless request_unchanged?(Toybaco::SubscriptionSyncRequest.lock.find(@record.id))

      before = return_facts(locked)
      @suspension_decision = decide.call(locked, subscription)
    end
    outcome = Toybaco::StoreFulfillment.synchronize(account, subscription_id: @record.subscription_id, client: client, guard: guard,
                                                             environment: @environment) do
      raise Toybaco::SubscriptionReconciliation::SuspensionChanged unless before && return_facts(Account.find(account.id)) == before
    end
    Rails.logger.error("TOYBACO_SUBSCRIPTION_SYNC_SUSPENSION_RETRY guard=#{@suspension_decision}") if outcome == 'renewal_pending'
  end

  # The request as suspend_after_attention's reload found it: still in attention, at the same revision.
  def request_unchanged?(request) = request.state == 'attention' && request.requested_revision == @record.requested_revision

  def return_facts(account)
    attrs = Toybaco::Entitlements.attributes(account)
    contract = attrs['toybaco_contract']
    { 'values' => attrs.slice(*RETURN_KEYS).deep_dup, 'free' => contract.is_a?(Hash) && contract['plan_id'] == 'free',
      'paid' => Toybaco::Growth::PeriodEndCancel.paid_contract?(contract),
      'records' => Toybaco::GrowthFreeReturn.where(account_id: account.id).count }
  end

  def expired_target
    account = bound_account if @environment['TOYBACO_STRIPE_MODE'] == @record.mode
    [account, mode_client] if account.is_a?(Account)
  end

  def mode_client
    ModeClient.new(@client || Toybaco::Checkout::Client.new(@environment.fetch('TOYBACO_STRIPE_KEY', '')), @record.mode)
  end

  # Webhook reconciliation only. The guard runs after the fresh provider read and
  # before any write, under the session lock shared with renewal dispatch, and returns
  # :wait, :status_only or nil (full Sync). The decision is kept for this run's expiry.
  def renewal_guard
    lambda do |account, subscription|
      @renewal_decision = Toybaco::Growth::RenewalDispatch.guard_sync!(account, subscription, now: now, environment: @environment)
    end
  end

  def bound_account
    account = @record.account_id ? current_account : bind_account
    return account if account.nil? || account == :superseded

    ids = Toybaco::SubscriptionReconciliation.accounts_for(@record.subscription_id).limit(2).pluck(:id)
    raise Toybaco::SubscriptionReconciliation::Invalid unless ids == [account.id]

    account
  end

  def current_account
    account = Account.find_by(id: @record.account_id)
    return :superseded unless account && account.internal_attributes&.fetch('toybaco_subscription_id', nil) == @record.subscription_id

    account
  end

  def bind_account
    accounts = Toybaco::SubscriptionReconciliation.accounts_for(@record.subscription_id).limit(2).to_a
    raise Toybaco::SubscriptionReconciliation::Invalid if accounts.size > 1
    return if accounts.empty?

    account = accounts.first
    @record.with_lock { @record.update!(account_id: account.id) }
    account
  end

  class ModeClient < SimpleDelegator
    def initialize(client, mode)
      super(client)
      @mode = mode
    end

    def retrieve_subscription(id)
      subscription = __getobj__.retrieve_subscription(id)
      raise Toybaco::SubscriptionReconciliation::Invalid unless subscription.is_a?(Hash) &&
                                                                subscription['id'] == id && subscription['livemode'] == (@mode == 'live')

      subscription
    end
  end
end
