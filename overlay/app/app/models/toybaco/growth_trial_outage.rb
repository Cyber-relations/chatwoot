# frozen_string_literal: true

class Toybaco::GrowthTrialOutage < ApplicationRecord
  self.table_name = 'toybaco_growth_trial_outages'

  validates :account_id, :starts_at, :ends_at, :confirmed_at, presence: true
  validates :incident_key, :operator_reference, format: { with: /\A[a-zA-Z0-9][a-zA-Z0-9_.:-]{4,119}\z/ }
  validates :report_digest, format: { with: /\A[0-9a-f]{64}\z/ }
end
