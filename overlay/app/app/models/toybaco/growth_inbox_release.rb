# frozen_string_literal: true

class Toybaco::GrowthInboxRelease < ApplicationRecord
  self.table_name = 'toybaco_growth_inbox_releases'

  belongs_to :account
  validates :request_id, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :receipt, presence: true

  def readonly?
    persisted?
  end
end
