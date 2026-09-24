# frozen_string_literal: true

class Toybaco::GrowthPostingExecution < ApplicationRecord
  self.table_name = 'toybaco_growth_posting_executions'
  self.record_timestamps = false
  attr_readonly :account_id, :operation_id, :identity_hash, :request, :request_hash
end
