# frozen_string_literal: true

class CreateToybacoGrowthTrialNotices < ActiveRecord::Migration[7.2]
  def change
    create_table :toybaco_growth_trial_notices do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :trial_id, null: false
      t.bigint :user_id, null: false
      t.string :kind, null: false
      t.string :state, null: false, default: 'queued'
      t.datetime :attempted_at
      t.timestamps
    end
    add_foreign_key :toybaco_growth_trial_notices, :toybaco_growth_trials, column: :trial_id, on_delete: :cascade
    add_index :toybaco_growth_trial_notices, [:trial_id, :kind], unique: true, name: 'toybaco_trial_notice_once'
    add_index :toybaco_growth_trial_notices, :state
    add_check_constraint :toybaco_growth_trial_notices, "kind IN ('deadline', 'remaining')", name: 'toybaco_trial_notice_kind'
    add_check_constraint :toybaco_growth_trial_notices, "state IN ('queued', 'dispatching', 'attempted', 'uncertain', 'cancelled')",
                         name: 'toybaco_trial_notice_state'
  end
end
