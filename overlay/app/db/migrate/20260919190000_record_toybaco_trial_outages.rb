# frozen_string_literal: true

class RecordToybacoTrialOutages < ActiveRecord::Migration[7.2]
  def change
    add_column :toybaco_growth_trials, :compensation_base_ends_at, :datetime
    add_column :toybaco_growth_trials, :compensated_seconds, :bigint, default: 0, null: false
    create_table :toybaco_growth_trial_outages do |t|
      # Like trial claims, the minimal incident audit survives account deletion.
      t.bigint :account_id, null: false
      t.string :incident_key, null: false
      t.string :report_digest, null: false
      t.string :operator_reference, null: false
      t.datetime :starts_at, null: false
      t.datetime :ends_at, null: false
      t.datetime :confirmed_at, null: false
      t.timestamps
    end
    add_index :toybaco_growth_trial_outages, [:account_id, :incident_key], unique: true, name: 'toybaco_trial_outage_once'
    add_check_constraint :toybaco_growth_trial_outages, 'ends_at > starts_at AND confirmed_at >= ends_at', name: 'toybaco_trial_outage_period'
    add_check_constraint :toybaco_growth_trials, 'compensated_seconds >= 0', name: 'toybaco_trial_compensated_seconds'
  end
end
