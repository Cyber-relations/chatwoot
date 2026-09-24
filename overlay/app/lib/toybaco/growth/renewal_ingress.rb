# frozen_string_literal: true

require_relative '../subscription_reconciliation'
require_relative 'renewal_invoice_snapshot'
require_relative 'renewal_dispatch'

# Admission only. A due timestamp is not permission to void, cancel or grant
# rights. Fact, revision and unverified operation commit with the source event.
module Toybaco::Growth::RenewalIngress
  module_function

  def invoice?(snapshot)
    %w[invoice.payment_failed invoice.paid].include?(snapshot['type']) &&
      snapshot.dig('data', 'object', 'billing_reason') == 'subscription_cycle'
  end

  def persist!(event, now:)
    raise Toybaco::Growth::BillingReceipt::Conflict unless Account.connection.transaction_open?
    return unless invoice?(event.snapshot)

    Toybaco::Growth::RenewalDispatch.admit_lock!(event)
    fields = fact_fields(event)
    previous = Toybaco::RenewalInvoiceFact.find_by(billing_event_id: event.id)
    return verify!(previous, event) if previous

    bind_revision!(event, now)
    create_fact!(event, fields, now: now)
  end

  def create_fact!(event, fields, now:)
    operation = Toybaco::RenewalOperation.create_or_find_by!(fields.slice(:mode, :subscription_id, :invoice_id)) do |row|
      row.customer_id = fields.fetch(:customer_id)
    end
    operation.with_lock do
      raise Toybaco::Growth::BillingReceipt::Conflict unless operation.customer_id == fields.fetch(:customer_id)

      fact = Toybaco::RenewalInvoiceFact.create!(fields.merge(billing_event_id: event.id, renewal_operation_id: operation.id,
                                                              payload_digest: digest(fields)))
      shorten_first_failure!(operation, fact)
      Toybaco::Growth::RenewalDispatch.accept!(operation, fact, now: now)
      fact
    end
  end

  def shorten_first_failure!(operation, fact)
    return unless first_failure?(fact) && (!operation.first_failed_at || fact.event_created_at < operation.first_failed_at)

    operation.update!(first_fact_id: fact.id, first_failed_at: fact.event_created_at, due_at: fact.event_created_at + 7.days,
                      state: 'unverified', result: nil)
  end

  def bind_revision!(event, now)
    return if event.subscription_sync_request_id

    request = Toybaco::SubscriptionReconciliation.persist_request!(event.reference_id, mode: event.mode, now: now)
    event.update!(subscription_sync_request_id: request.id, requested_revision: request.requested_revision)
  end

  def fact_fields(event)
    snapshot = event.snapshot
    invoice = Toybaco::Growth::RenewalInvoiceSnapshot.read(snapshot.fetch('data').fetch('object'), snapshot.fetch('type'))
    raise Toybaco::Growth::BillingReceipt::Conflict unless invoice && invoice.fetch('subscription') == event.reference_id

    { event_id: event.event_id, event_type: snapshot.fetch('type'), mode: event.mode, subscription_id: invoice.fetch('subscription'),
      invoice_id: invoice.fetch('id'), customer_id: invoice.fetch('customer'), attempt_count: invoice.fetch('attempt_count'),
      event_created_at: Time.at(snapshot.fetch('created')).utc }
  end

  def digest(fields)
    value = fields.stringify_keys.transform_values { |item| item.is_a?(Time) ? item.to_i : item }
    Toybaco::Growth::BillingReceipt.snapshot_digest(value)
  end

  def verify!(fact, event)
    fields = fact_fields(event)
    raise Toybaco::Growth::BillingReceipt::Conflict unless fact && fact.attributes.slice(*fields.keys.map(&:to_s)) == fields.stringify_keys &&
                                                           fact.payload_digest == digest(fields)

    fact
  end

  def first_failure?(fact)
    fact.event_type == 'invoice.payment_failed' && fact.attempt_count == 1
  end
end
