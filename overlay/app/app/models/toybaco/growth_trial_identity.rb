# frozen_string_literal: true

class Toybaco::GrowthTrialIdentity < ApplicationRecord
  self.table_name = 'toybaco_growth_trial_identities'

  belongs_to :trial, class_name: 'Toybaco::GrowthTrial', inverse_of: :identities
  validates :provider, :identity_digest, presence: true
end
