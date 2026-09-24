# frozen_string_literal: true

class Toybaco::GrowthPostingAuthorityCurrent < ApplicationRecord
  self.table_name = 'toybaco_growth_posting_authority_currents'
  self.primary_key = 'account_id'
  self.record_timestamps = false
  attr_readonly :account_id
end
