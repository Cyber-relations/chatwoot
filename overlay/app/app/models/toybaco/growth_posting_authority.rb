# frozen_string_literal: true

class Toybaco::GrowthPostingAuthority < ApplicationRecord
  self.table_name = 'toybaco_growth_posting_authorities'
  self.record_timestamps = false
  attr_readonly :account_id, :authority_id, :preparation_request_id, :receipt
end
