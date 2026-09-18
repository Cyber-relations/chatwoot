# frozen_string_literal: true

class Toybaco::GrowthTrial < ApplicationRecord
  self.table_name = 'toybaco_growth_trials'

  has_many :identities, class_name: 'Toybaco::GrowthTrialIdentity', foreign_key: :trial_id, inverse_of: :trial, dependent: :restrict_with_exception
  validates :account_id, :facts_revision, :example_id, :starts_at, :ends_at, presence: true
end
