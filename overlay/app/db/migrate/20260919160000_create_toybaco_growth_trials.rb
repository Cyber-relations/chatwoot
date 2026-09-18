# frozen_string_literal: true

class CreateToybacoGrowthTrials < ActiveRecord::Migration[7.2]
  def change
    create_table :toybaco_growth_trials do |t|
      # These minimal claims survive account deletion to prevent reissuing a trial.
      t.bigint :account_id, null: false
      t.string :facts_revision, null: false
      t.bigint :example_id, null: false
      t.datetime :starts_at, null: false
      t.datetime :ends_at, null: false
      t.datetime :completed_at
      t.string :completion_reason
      t.timestamps
    end
    add_index :toybaco_growth_trials, :account_id, unique: true
    add_check_constraint :toybaco_growth_trials, 'ends_at > starts_at', name: 'toybaco_trial_period'

    create_identities
  end

  private

  def create_identities
    create_table :toybaco_growth_trial_identities do |t|
      t.bigint :trial_id, null: false
      t.string :provider, null: false
      t.string :identity_digest, null: false
      t.timestamps
    end
    add_index :toybaco_growth_trial_identities, [:provider, :identity_digest], unique: true, name: 'toybaco_trial_external_identity'
    add_index :toybaco_growth_trial_identities, :trial_id
    add_foreign_key :toybaco_growth_trial_identities, :toybaco_growth_trials, column: :trial_id
  end
end
