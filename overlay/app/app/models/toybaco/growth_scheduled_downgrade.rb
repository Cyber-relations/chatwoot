# frozen_string_literal: true

class Toybaco::GrowthScheduledDowngrade < ApplicationRecord
  self.table_name = 'toybaco_growth_scheduled_downgrades'
  attr_readonly :account_id, :renewal_operation_id, :receipt, :receipt_hash
end
