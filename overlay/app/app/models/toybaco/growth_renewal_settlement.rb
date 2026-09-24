# frozen_string_literal: true

class Toybaco::GrowthRenewalSettlement < ApplicationRecord
  self.table_name = 'toybaco_growth_renewal_settlements'
  attr_readonly :account_id, :coordinator_id, :operation_id, :receipt, :receipt_hash
end
