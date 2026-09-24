# frozen_string_literal: true

class Toybaco::GrowthPostingRenewal < ApplicationRecord
  self.table_name = 'toybaco_growth_posting_renewals'
  self.record_timestamps = false
  attr_readonly :account_id, :request_id, :source_authority_id, :target_authority_id, :kind, :mode, :subscription_id, :invoice_id, :receipt
end
