# frozen_string_literal: true

class Toybaco::RenewalInvoiceFact < ApplicationRecord
  self.table_name = 'toybaco_renewal_invoice_facts'
  attr_readonly :billing_event_id, :renewal_operation_id, :event_id, :event_type, :mode, :subscription_id, :customer_id,
                :invoice_id, :attempt_count, :event_created_at, :payload_digest
end
