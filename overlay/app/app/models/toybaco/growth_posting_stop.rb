# frozen_string_literal: true

class Toybaco::GrowthPostingStop < ApplicationRecord
  self.table_name = 'toybaco_growth_posting_stops'
  self.record_timestamps = false
  attr_readonly :account_id, :operation_id, :contract_hash, :target_hash, :request_hash
end
