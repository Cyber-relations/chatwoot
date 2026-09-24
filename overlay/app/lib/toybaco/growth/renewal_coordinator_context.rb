# frozen_string_literal: true

require_relative 'renewal_coordinator_record'
require_relative 'renewal_transition'
require_relative 'paid_period'
require_relative 'purchase_intent'
require_relative 'posting_owner_inventory'

# Local source capture only. The shared ordinary-renewal reader owns all
# provider and invoice business rules, outside this Account transaction.
module Toybaco::Growth::RenewalCoordinatorContext
  Record = Toybaco::Growth::RenewalCoordinatorRecord
  Execution = Toybaco::Growth::PostingExecutionContext
  Principal = Toybaco::Growth::PostingPrincipal

  module_function

  def capture(account, operation_id, environment:, now:)
    require_relative 'ordinary_renewal_fact'
    failure = Toybaco::Growth::OrdinaryRenewalFact.read!(operation_id, account: account, now: now)
    raise Record::Changed unless failure['mode'] == environment['TOYBACO_STRIPE_MODE'] && now.to_i >= failure.fetch('due_at')

    attrs = Toybaco::Entitlements.attributes(account)
    binding = binding!(account, attrs, failure)
    owner = attrs['toybaco_billing_owner_user_id']
    raise Record::Changed unless account.active? && owner.is_a?(Integer) && owner.positive?

    member = Principal.capture_member!(account, owner, owner, now)
    { 'failure' => failure, 'binding' => binding, 'contract_hash' => Execution.contract_hash(account),
      'principal' => member, 'selection_hash' => Record.digest(attrs[Toybaco::Growth::RetentionSnapshot::KEY]),
      'billing_hash' => billing_hash!(account, attrs) }
  end

  def binding!(account, attrs, failure)
    contract = Toybaco::Entitlements.contract_for(account)
    source = { 'contract' => contract, 'subscription_id' => attrs['toybaco_subscription_id'],
               'customer_id' => attrs['toybaco_stripe_customer_id'], 'mode' => failure['mode'] }
    operation = Toybaco::RenewalOperation.find(failure.fetch('operation_id'))
    raise Record::Changed unless operation.source_hash == Toybaco::Growth::BillingReceipt.snapshot_digest(source)
    raise Record::Changed unless source.values_at('subscription_id', 'customer_id') == failure.values_at('subscription_id', 'customer_id')

    source.merge('purchase_nonce' => purchase_nonce!(attrs, failure),
                 'coverage' => attrs[Toybaco::Growth::PaidPeriod::KEY]&.except('current_period_start', 'current_base_limit'))
  end

  def purchase_nonce!(attrs, failure)
    purchase = attrs[Toybaco::Growth::PurchaseIntent::KEY]
    raise Record::Changed unless purchase.is_a?(Hash) && purchase['state'] == 'complete' &&
                                 purchase['subscription_id'] == failure['subscription_id'] && purchase['livemode'] == (failure['mode'] == 'live')

    purchase['nonce']
  end

  def billing_hash!(account, attrs)
    raise Record::Changed if attrs['toybaco_billing_review'] || attrs['toybaco_billing_payment_pending'] || attrs['toybaco_billing_suspended'] ||
                             attrs.key?('toybaco_store_purchase')

    terminal!(attrs['toybaco_plan_change'], %w[applied released expired])
    terminal!(attrs['toybaco_cancel_request'], ['complete'])
    raise Record::Changed if Toybaco::GrowthPackOrder.where(account_id: account.id).where.not(state: %w[complete expired refunded]).exists?

    Record.digest(attrs.slice('toybaco_plan_change', 'toybaco_cancel_request', 'toybaco_subscription_status',
                              'toybaco_growth_renewal_failure'))
  end

  def terminal!(value, states)
    raise Record::Changed unless value.nil? || (value.is_a?(Hash) && states.include?(value['status']))
  end

  def target_hash(account)
    attrs = Toybaco::Entitlements.attributes(account).except(Toybaco::Growth::PurchaseIntent::KEY, 'toybaco_subscription_id')
    projected = Toybaco::Entitlements.project_attributes(attrs, Toybaco::Growth::FreeReturnRecord.free_contract)
    Record.digest(Execution.binding('active', projected))
  end

  def inventory(account)
    owner = User.find(Toybaco::Entitlements.attributes(account).fetch('toybaco_billing_owner_user_id'))
    Toybaco::Growth::PostingOwnerInventory.new(account, owner)
  end
end
