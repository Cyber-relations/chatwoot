# frozen_string_literal: true

class Toybaco::GrowthPostingPaidUpgrade < ApplicationRecord
  self.table_name = 'toybaco_growth_posting_paid_upgrades'
  self.record_timestamps = false
  attr_readonly :account_id, :operation_id, :receipt
end
