# frozen_string_literal: true

class Toybaco::GrowthRenewalCoordinator < ApplicationRecord
  self.table_name = 'toybaco_growth_renewal_coordinators'
  attr_readonly :account_id, :renewal_operation_id, :operation_id, :due_at, :receipt, :receipt_hash
end
