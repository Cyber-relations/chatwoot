# frozen_string_literal: true

class Toybaco::GrowthPostingPrincipal < ApplicationRecord
  self.table_name = 'toybaco_growth_posting_principals'
  self.record_timestamps = false
  attr_readonly :account_id, :user_id
end
