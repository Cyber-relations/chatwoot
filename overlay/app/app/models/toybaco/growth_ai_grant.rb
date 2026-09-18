# frozen_string_literal: true

class Toybaco::GrowthAiGrant < ApplicationRecord
  self.table_name = 'toybaco_growth_ai_grants'

  belongs_to :account
  has_many :operations, class_name: 'Toybaco::GrowthAiOperation', foreign_key: :grant_id, inverse_of: :grant, dependent: :delete_all

  validates :source, inclusion: { in: %w[included grace pack trial] }
  validates :source_key, presence: true, length: { maximum: 160 }
  validates :units, :used, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :starts_at, :ends_at, presence: true
end
