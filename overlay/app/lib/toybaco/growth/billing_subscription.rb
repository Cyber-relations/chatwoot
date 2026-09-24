# frozen_string_literal: true

require_relative '../subscription_reconciliation'
require_relative 'billing_receipt'

module Toybaco::Growth::BillingSubscription
  module_function

  def accept!(event, now: Time.now.utc)
    request = bind!(event, now: now)
    Toybaco::SubscriptionReconciliation::Dispatch.enqueue(request, now: now)
    request
  end

  # Verifies the event and binds it to its Sync request without enqueueing: a bound event
  # reads its request, an unbound one records it (persist_request!). The caller enqueues.
  def bind!(event, now: Time.now.utc)
    raise Toybaco::SubscriptionReconciliation::Invalid if Account.connection.transaction_open?

    event.with_lock do
      verify_event!(event)
      event.subscription_sync_request_id ? read_request!(event) : record_request!(event, now)
    end
  end

  def verify_event!(event)
    Toybaco::Growth::BillingReceipt.verify!(event)
    valid = event.action == 'subscription_notice' && event.reference_id.match?(/\Asub_[A-Za-z0-9]{1,200}\z/) &&
            event.snapshot.dig('data', 'object', 'subscription') == event.reference_id
    raise Toybaco::SubscriptionReconciliation::Invalid unless valid
  end

  def read_request!(event)
    request = Toybaco::SubscriptionSyncRequest.find(event.subscription_sync_request_id)
    valid = request.subscription_id == event.reference_id && request.mode == event.mode &&
            event.requested_revision.positive? && request.requested_revision >= event.requested_revision
    raise Toybaco::SubscriptionReconciliation::Invalid unless valid

    request
  end

  def record_request!(event, now)
    request = Toybaco::SubscriptionReconciliation.persist_request!(event.reference_id, mode: event.mode, now: now)
    event.update!(subscription_sync_request_id: request.id, requested_revision: request.requested_revision)
    request
  end
end
