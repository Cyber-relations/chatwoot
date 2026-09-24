# frozen_string_literal: true

class Toybaco::GrowthAutoCommand < ApplicationRecord
  self.table_name = 'toybaco_growth_auto_commands'
  validates :account_id, :installation_id, :actor_id, :request_id, :request_hash, presence: true

  def readonly?
    persisted?
  end
end
