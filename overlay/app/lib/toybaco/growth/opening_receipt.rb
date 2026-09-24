# frozen_string_literal: true

require_relative 'billing_receipt'

module Toybaco::Growth::OpeningReceipt
  module_function

  def enabled?
    ENV['TOYBACO_OPENING_INGRESS_ENABLED'] == 'true'
  end

  def bind!(event)
    raise Toybaco::Growth::BillingReceipt::Conflict if Account.connection.transaction_open?

    event.with_lock do
      Toybaco::Growth::BillingReceipt.verify!(event)
      raise Toybaco::Growth::PaymentSignature::Invalid unless event.action == 'opening_checkout'

      row = Toybaco::OpeningRequest.create_or_find_by!(mode: event.mode, session_id: event.reference_id) do |value|
        value.deadline_at = event.deadline_at
      end
      raise Toybaco::Growth::BillingReceipt::Conflict if event.opening_request_id && event.opening_request_id != row.id

      event.update!(opening_request_id: row.id) unless event.opening_request_id
      row
    end
  end
end
