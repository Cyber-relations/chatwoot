# frozen_string_literal: true

class Toybaco::GrowthPostingPreparationAck < ApplicationRecord
  self.table_name = 'toybaco_growth_posting_preparation_acks'
  self.record_timestamps = false

  validates :account_id, numericality: { only_integer: true, greater_than: 0 }
  validates :request_id, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :receipt, presence: true

  def readonly?
    persisted?
  end
end
