# frozen_string_literal: true

class Toybaco::GrowthScheduledGrantUpgrade < ApplicationRecord
  self.table_name = 'toybaco_growth_scheduled_grant_upgrades'
  attr_readonly :account_id, :scheduled_downgrade_id, :grant_id, :operation_id, :parent_hash, :receipt, :receipt_hash, :created_at, :updated_at
end
