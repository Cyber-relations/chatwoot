# frozen_string_literal: true

require_relative '../billing_access'
require_relative 'renewal_settlement'
require_relative 'free_return_record'
require_relative 'paid_coverage'
require_relative 'paid_period'
require_relative 'purchase_intent'

module Toybaco::Growth::InboxReleaseContext
  Record = Toybaco::Growth::InboxReleaseRecord

  private

  def authorize!
    raise Record::Invalid unless @account.active? && Toybaco::BillingAccess.permissions(@account, @user)[:can_manage_billing]
  end

  def snapshot!
    authorize!
    attrs = Toybaco::Entitlements.attributes(@account)
    raise Record::Invalid if Toybaco::Growth::RenewalTransition.pending?(@account) || blocked_billing?(attrs)

    hold, returned = source_hold!(attrs)
    epochs = Toybaco::Growth::InboxDeliveryEpoch.current(@account.id, attrs, hold, now: @now)
    binding = binding!(attrs, returned)
    previous = Record.current(@account.id, attrs, hold, now: @now)
    keep = Record.effective_ids(@account.id, attrs, hold, now: @now)
    rows = inbox_rows!(keep)
    { 'hold' => hold, 'free_return_hash' => returned['receipt_hash'], 'binding' => binding,
      'previous_id' => previous&.fetch('request_id'), 'keep_inbox_ids' => keep,
      'rows' => rows, 'owner_id' => @user.id,
      'revision' => Toybaco::Growth::RetentionSnapshot.fingerprint(
        [hold, epochs['receipt_hash'], returned['receipt_hash'], binding, previous, keep, rows.pluck('id'), @user.id]
      ) }
  end

  def source_hold!(attrs)
    hold = Toybaco::Growth::InboxRetention.validate!(attrs[Toybaco::Growth::InboxRetention::KEY], account_id: @account.id, now: @now)
    returned = Toybaco::Growth::FreeReturnRecord.current(@account)
    raise Record::Invalid unless returned && returned['inbox'] == hold && attrs[Toybaco::Growth::PostingRetention::KEY] == returned['posting']

    [hold, returned]
  end

  def inbox_rows!(keep)
    rows = @account.inboxes.order(:id).limit(10_001).pluck(:id, :name).map { |id, name| { 'id' => id.to_s, 'name' => name } }
    raise Record::Invalid if rows.size > 10_000 || (keep - rows.pluck('id')).any?

    rows
  end

  def blocked_billing?(attrs)
    attrs['toybaco_billing_review'] || attrs['toybaco_billing_payment_pending'] || attrs['toybaco_subscription_status'] != 'active' ||
      attrs.key?(Toybaco::Growth::RenewalSettlement::FAILURE_KEY) || attrs.key?(Toybaco::StoreFulfillment::PURCHASE)
  end

  def binding!(attrs, returned)
    contract = Toybaco::Entitlements.contract_for(@account)
    Record.inbox_limit(contract)
    purchase = purchase!(attrs, returned)

    binding = { 'contract' => contract, 'subscription_id' => attrs['toybaco_subscription_id'],
                'customer_id' => attrs['toybaco_stripe_customer_id'], 'mode' => @environment['TOYBACO_STRIPE_MODE'],
                'purchase_nonce' => purchase['nonce'],
                'coverage' => attrs[Toybaco::Growth::PaidPeriod::KEY]&.except('current_period_start', 'current_base_limit') }
    raise Record::Invalid unless Record.valid_binding?(binding) && coverage_current?(binding, returned['returned_at'])

    binding
  end

  def purchase!(attrs, returned)
    purchase = attrs[Toybaco::Growth::PurchaseIntent::KEY]
    raise Record::Invalid unless purchase.is_a?(Hash) && purchase['state'] == 'complete' &&
                                 purchase['subscription_id'] == attrs['toybaco_subscription_id'] &&
                                 purchase['subscription_id'] != returned.dig('source_journal', 'binding', 'subscription_id')
    raise Record::Invalid unless %w[test live].include?(@environment['TOYBACO_STRIPE_MODE']) &&
                                 purchase['livemode'] == (@environment['TOYBACO_STRIPE_MODE'] == 'live')

    purchase
  end

  def coverage_current?(binding, returned_at)
    coverage, contract = binding.values_at('coverage', 'contract')
    %w[plan_id plan_version cycle stripe_price_id].all? { |key| coverage[key] == contract[key] } &&
      %w[term_start term_end paid_at].all? { |key| coverage[key].is_a?(Integer) } &&
      coverage['term_start'] <= @now.to_i && coverage['term_end'] > @now.to_i &&
      coverage['paid_at'].between?(returned_at, @now.to_i)
  end

  def verify_provider!(context)
    binding = context.fetch('binding')
    raise Record::Invalid if @account.class.connection.transaction_open?

    subscription = @client.retrieve_subscription(binding['subscription_id'])
    raise Record::Invalid unless provider_matches?(subscription, binding) &&
                                 Toybaco::Growth::PaidCoverage.new(subscription, binding['contract']).verified == binding['coverage']
  end

  def provider_matches?(subscription, binding)
    subscription.is_a?(Hash) && subscription['id'] == binding['subscription_id'] &&
      subscription['customer'] == binding['customer_id'] && subscription['livemode'] == (binding['mode'] == 'live') &&
      subscription['pending_update'].nil? && subscription.dig('metadata', 'toybaco_purchase_nonce') == binding['purchase_nonce']
  end
end
