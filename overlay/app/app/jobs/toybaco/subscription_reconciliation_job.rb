# frozen_string_literal: true

require_relative '../../../lib/toybaco/subscription_reconciliation/execution'

class Toybaco::SubscriptionReconciliationJob < ApplicationJob
  queue_as :default

  def perform(request_id)
    return unless request_id.is_a?(Integer) && request_id.positive?

    record = Toybaco::SubscriptionSyncRequest.find_by(id: request_id)
    Toybaco::SubscriptionReconciliation::Execution.new(record).call if record
  end
end
