# frozen_string_literal: true

class CreateToybacoGrowthPostingStops < ActiveRecord::Migration[7.1]
  def change
    create_table :toybaco_growth_posting_stops do |t|
      # Minimal transition history survives account deletion.
      t.bigint :account_id, null: false
      t.string :operation_id, null: false
      t.string :contract_hash, null: false
      t.string :target_hash, null: false
      t.string :request_hash, null: false
      t.string :state, null: false, default: 'pending'
      t.datetime :terminal_at
      t.timestamps
    end
    add_index :toybaco_growth_posting_stops, [:account_id, :operation_id], unique: true, name: 'toybaco_posting_stop_operation'
    add_index :toybaco_growth_posting_stops, :account_id, unique: true, where: "state = 'pending'", name: 'toybaco_posting_stop_pending'
    add_check_constraint :toybaco_growth_posting_stops, <<~SQL.squish, name: 'toybaco_posting_stop_state'
      account_id > 0 AND contract_hash <> target_hash AND updated_at >= created_at AND (
        (state = 'pending' AND terminal_at IS NULL) OR
        (state IN ('applied', 'withdrawn') AND terminal_at IS NOT NULL AND terminal_at >= created_at AND terminal_at <= updated_at)
      )
    SQL
  end
end
