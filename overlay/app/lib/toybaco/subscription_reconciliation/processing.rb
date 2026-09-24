# frozen_string_literal: true

require 'delegate'

module Toybaco::SubscriptionReconciliation::Processing
  private

  def reconcile
    return 'attention' unless @environment['TOYBACO_STRIPE_MODE'] == @record.mode

    account = bound_account
    return 'superseded' if account == :superseded
    return retry_missing_account unless account

    client = @client || Toybaco::Checkout::Client.new(@environment.fetch('TOYBACO_STRIPE_KEY', ''))
    checked = ModeClient.new(client, @record.mode)
    # This method retains the existing subscription lock, complete parent /
    # child transaction and current-subscription checks. The request claim
    # was committed separately before any Stripe read or business update.
    outcome = Toybaco::StoreFulfillment.synchronize(account, subscription_id: @record.subscription_id, client: checked)
    %w[applied payment_pending].include?(outcome) ? outcome : 'attention'
  end

  def retry_missing_account
    raise Toybaco::SubscriptionReconciliation::NotProvisioned
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
