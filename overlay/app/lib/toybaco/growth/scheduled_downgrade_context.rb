# frozen_string_literal: true

require_relative 'billing_receipt'
require_relative 'renewal_ingress'
require_relative 'posting_principal'
require_relative 'paid_period'
require_relative 'purchase_intent'

module Toybaco::Growth::ScheduledDowngradeContext
  Invalid = Toybaco::Growth::PostingPreparationRecord::Invalid
  FIELDS = %w[mode subscription_id customer_id invoice_id].freeze

  module_function

  def fact!(operation, now)
    raise Invalid unless Account.connection.transaction_open? && operation.first_fact_id

    first = Toybaco::RenewalInvoiceFact.find_by(id: operation.first_fact_id)
    event = first && Toybaco::BillingEvent.find_by(id: first.billing_event_id)
    raise Invalid unless event

    Toybaco::Growth::BillingReceipt.verify!(event)
    Toybaco::Growth::RenewalIngress.verify!(first, event)
    identity!(operation, first, now)
    operation.attributes.slice(*FIELDS).merge('operation_id' => operation.id, 'fact_id' => first.id, 'fact_hash' => first.payload_digest,
                                              'first_failed_at' => operation.first_failed_at.to_i, 'due_at' => operation.due_at.to_i)
  end

  def identity!(operation, first, now)
    raise Invalid unless first.renewal_operation_id == operation.id && Toybaco::Growth::RenewalIngress.first_failure?(first) &&
                         first.attributes.slice(*FIELDS) == operation.attributes.slice(*FIELDS)
    raise Invalid unless operation.first_failed_at == first.event_created_at && operation.first_failed_at <= now &&
                         operation.due_at == first.event_created_at + 604_800
  end

  def capture(account, operation, now, environment)
    failure = fact!(operation, now)
    attrs = Toybaco::Entitlements.attributes(account)
    contract = contract!(account, attrs)
    binding!(account, operation, attrs, failure, environment)
    receipt = attrs.fetch(Toybaco::Checkout::PlanChange::RECEIPT_KEY)
    owner = attrs['toybaco_billing_owner_user_id']
    raise Invalid unless receipt.dig('quote', 'user_id') == owner

    principal = Toybaco::Growth::PostingPrincipal.capture_member!(account, owner, owner, now)
    coverage = attrs.fetch(Toybaco::Growth::PaidPeriod::KEY).except('current_period_start', 'current_base_limit')
    binding = failure.slice('mode', 'subscription_id', 'customer_id')
                     .merge('contract' => contract, 'purchase_nonce' => nonce!(attrs, failure), 'coverage' => coverage)
    { 'account_id' => account.id, 'binding' => binding, 'failure' => failure, 'reservation' => receipt.deep_dup, 'principal' => principal }
  end

  def contract!(account, attrs)
    contract = Toybaco::Entitlements.contract_for(account)
    raise Invalid unless account.active? && contract['legacy'] == false && contract.fetch('addons').empty? &&
                         contract.dig('entitlements', 'ai_meter') == Toybaco::GrowthTerms::METER
    raise Invalid if %w[toybaco_billing_suspended toybaco_billing_review toybaco_cancel_at_period_end
                        toybaco_cancel_request toybaco_store_purchase].any? { |key| attrs[key] }

    contract
  end

  def binding!(account, operation, attrs, failure, environment)
    raise Invalid unless failure.values_at('subscription_id', 'customer_id', 'mode') ==
                         [attrs['toybaco_subscription_id'], attrs['toybaco_stripe_customer_id'], environment['TOYBACO_STRIPE_MODE']]
    raise Invalid if operation.account_id && operation.account_id != account.id
  end

  def nonce!(attrs, failure)
    purchase = attrs[Toybaco::Growth::PurchaseIntent::KEY]
    raise Invalid unless purchase.is_a?(Hash) && purchase['state'] == 'complete' && purchase['subscription_id'] == failure['subscription_id'] &&
                         purchase['livemode'] == (failure['mode'] == 'live')

    purchase.fetch('nonce')
  end
end
