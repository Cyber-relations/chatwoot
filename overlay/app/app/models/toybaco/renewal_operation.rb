# frozen_string_literal: true

class Toybaco::RenewalOperation < ApplicationRecord
  self.table_name = 'toybaco_renewal_operations'
  attr_readonly :mode, :subscription_id, :customer_id, :invoice_id
end
