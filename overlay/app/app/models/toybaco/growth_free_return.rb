# frozen_string_literal: true

class Toybaco::GrowthFreeReturn < ApplicationRecord
  self.table_name = 'toybaco_growth_free_returns'

  belongs_to :account
  validates :transition_id, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :receipt, presence: true

  def readonly?
    persisted?
  end
end
