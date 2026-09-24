# frozen_string_literal: true

require_relative 'posting_preparation_record'

# A signed first-attempt origin is necessary, but is not ordinary-invoice or
# paid-coverage evidence. The caller holds the current Account row lock.
module Toybaco::Growth::OrdinaryRenewalFact
  Invalid = Toybaco::Growth::PostingPreparationRecord::Invalid
  FIELDS = %w[mode subscription_id customer_id invoice_id].freeze

  module_function

  def read!(operation_id, account:, now:)
    raise Invalid unless Account.connection.transaction_open?

    validate_operation_id!(operation_id)

    require_relative 'renewal_ingress'
    require_relative 'billing_receipt'
    operation = Toybaco::RenewalOperation.lock('FOR UPDATE NOWAIT').find_by(id: operation_id)
    raise Invalid unless operation&.account_id == account.id
    raise Invalid unless operation.first_fact_id

    origin!(operation, now)
  rescue ActiveRecord::LockWaitTimeout
    raise Toybaco::Growth::PostingExecutionContext::Busy
  end

  def validate_operation_id!(operation_id)
    raise Invalid unless operation_id.is_a?(Integer) && operation_id.positive?
  end

  def origin!(operation, now)
    fact = Toybaco::RenewalInvoiceFact.find_by(id: operation.first_fact_id)
    event = fact && Toybaco::BillingEvent.find_by(id: fact.billing_event_id)
    raise Invalid unless event

    Toybaco::Growth::BillingReceipt.verify!(event)
    Toybaco::Growth::RenewalIngress.verify!(fact, event)
    validate!(operation, fact, now)
    snapshot(operation, fact)
  rescue ActiveRecord::LockWaitTimeout
    raise Toybaco::Growth::PostingExecutionContext::Busy
  end

  def validate!(operation, fact, now)
    raise Invalid unless fact.renewal_operation_id == operation.id && fact.event_type == 'invoice.payment_failed' && fact.attempt_count == 1
    raise Invalid unless operation.attributes.slice(*FIELDS) == fact.attributes.slice(*FIELDS)

    validate_times!(operation, fact, now)
  end

  def validate_times!(operation, fact, now)
    raise Invalid unless operation.first_failed_at == fact.event_created_at && operation.due_at == fact.event_created_at + 604_800
    raise Invalid unless operation.first_failed_at.to_i.positive? && operation.first_failed_at <= now

    verified_time!(operation, now)
  end

  def verified_time!(operation, now)
    raise Invalid unless operation.verified_at&.between?(operation.first_failed_at, now)
    raise Invalid unless %w[observed_failure resolved_observation].include?(operation.state)
  end

  def snapshot(operation, fact)
    operation.attributes.slice(*FIELDS).merge(
      'operation_id' => operation.id, 'fact_id' => fact.id, 'fact_hash' => fact.payload_digest,
      'first_failed_at' => operation.first_failed_at.to_i, 'due_at' => operation.due_at.to_i
    )
  end
end
