# frozen_string_literal: true

class Toybaco::GrowthAutoInstallation < ApplicationRecord
  self.table_name = 'toybaco_growth_auto_installations'
  validates :account_id, :inbox_id, :bot_id, :actor_id, :request_id, :epoch, presence: true
  validates :generation, numericality: { only_integer: true, greater_than: 0 }
  validates :state, inclusion: { in: %w[draft auto stopping stopped] }
end
