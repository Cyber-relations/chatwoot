# frozen_string_literal: true

class CreateToybacoGrowthPostingExecutions < ActiveRecord::Migration[7.1]
  def change
    create_table :toybaco_growth_posting_executions do |t|
      # Deliberately retained after account deletion; no customer content.
      t.bigint :account_id, null: false
      t.string :operation_id, null: false
      t.string :identity_hash, null: false
      t.jsonb :request, null: false
      t.string :request_hash, null: false
      t.string :state, null: false, default: 'prepared'
      t.datetime :started_at
      t.datetime :terminal_at
      t.string :outcome
      t.string :evidence_hash
      t.timestamps
    end
    add_execution_indexes
    add_check_constraint :toybaco_growth_posting_executions, state_constraint, name: 'toybaco_posting_execution_state'
  end

  private

  def add_execution_indexes
    add_index :toybaco_growth_posting_executions, [:account_id, :operation_id], unique: true, name: 'toybaco_posting_execution_operation'
    add_index :toybaco_growth_posting_executions, [:account_id, :identity_hash], unique: true, name: 'toybaco_posting_execution_identity'
    add_index :toybaco_growth_posting_executions, [:account_id, :state], name: 'toybaco_posting_execution_pending'
  end

  def state_constraint
    <<~SQL.squish
      account_id > 0 AND (
        (state = 'prepared' AND started_at IS NULL AND terminal_at IS NULL AND outcome IS NULL AND evidence_hash IS NULL) OR
        (state IN ('started', 'uncertain') AND started_at IS NOT NULL AND terminal_at IS NULL AND outcome IS NULL AND evidence_hash IS NULL) OR
        (state = 'cancelled' AND started_at IS NULL AND terminal_at IS NOT NULL AND outcome IS NULL AND evidence_hash IS NULL) OR
        (state = 'completed' AND started_at IS NOT NULL AND terminal_at IS NOT NULL AND outcome IS NOT NULL AND outcome IN ('published', 'rejected') AND evidence_hash IS NOT NULL)
      )
    SQL
  end
end
