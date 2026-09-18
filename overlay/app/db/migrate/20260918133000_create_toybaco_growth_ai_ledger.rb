# frozen_string_literal: true

class CreateToybacoGrowthAiLedger < ActiveRecord::Migration[7.2]
  def change
    create_table :toybaco_growth_ai_grants do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.string :source, null: false
      t.string :source_key, null: false
      t.integer :units, null: false
      t.integer :used, null: false, default: 0
      t.datetime :starts_at, null: false
      t.datetime :ends_at, null: false
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :toybaco_growth_ai_grants, [:account_id, :source, :source_key], unique: true, name: 'toybaco_ai_grant_identity'
    add_index :toybaco_growth_ai_grants, [:id, :account_id], unique: true, name: 'toybaco_ai_grant_store'
    add_check_constraint :toybaco_growth_ai_grants, 'units >= 0 AND used >= 0 AND used <= units', name: 'toybaco_ai_grant_amount'
    add_check_constraint :toybaco_growth_ai_grants, 'ends_at > starts_at', name: 'toybaco_ai_grant_period'
    add_check_constraint :toybaco_growth_ai_grants, "source IN ('included', 'grace', 'pack', 'trial')", name: 'toybaco_ai_grant_source'

    create_operations
  end

  private

  def create_operations
    create_table :toybaco_growth_ai_operations do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :grant_id, null: false
      t.string :request_key, null: false
      t.string :kind, null: false
      t.string :context_digest, null: false
      t.string :token_digest, null: false
      t.string :state, null: false, default: 'reserved'
      t.datetime :lease_expires_at, null: false
      t.string :result_reference
      t.timestamps
    end
    add_index :toybaco_growth_ai_operations, [:account_id, :request_key], unique: true, name: 'toybaco_ai_operation_identity'
    add_index :toybaco_growth_ai_operations, [:grant_id, :state, :lease_expires_at], name: 'toybaco_ai_active_reservations'
    add_foreign_key :toybaco_growth_ai_operations, :toybaco_growth_ai_grants, column: [:grant_id, :account_id],
                                                                              primary_key: [:id, :account_id], on_delete: :cascade
    add_check_constraint :toybaco_growth_ai_operations, "state IN ('reserved', 'consumed', 'released', 'expired')", name: 'toybaco_ai_operation_state'
    add_check_constraint :toybaco_growth_ai_operations, "kind IN ('reply_draft', 'post_draft', 'automatic_reply')", name: 'toybaco_ai_operation_kind'
  end
end
