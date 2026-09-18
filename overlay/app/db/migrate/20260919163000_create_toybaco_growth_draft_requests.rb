# frozen_string_literal: true

class CreateToybacoGrowthDraftRequests < ActiveRecord::Migration[7.2]
  def change
    create_table :toybaco_growth_draft_requests do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :user_id, null: false
      t.bigint :conversation_id, null: false
      t.bigint :incoming_id, null: false
      t.bigint :public_tail_id, null: false
      t.bigint :operation_id, null: false
      t.string :state, null: false, default: 'queued'
      t.text :encrypted_input
      t.string :draft_digest, null: false
      t.string :facts_revision, null: false
      t.datetime :started_at
      t.datetime :expires_at, null: false
      t.string :error_code
      t.timestamps
    end
    add_request_constraints
  end

  private

  def add_request_constraints
    add_index :toybaco_growth_draft_requests, :operation_id, unique: true
    add_index :toybaco_growth_draft_requests, [:account_id, :user_id, :conversation_id, :state], name: 'toybaco_draft_actor_conversation'
    add_index :toybaco_growth_draft_requests, [:state, :expires_at]
    add_index :toybaco_growth_ai_operations, [:id, :account_id], unique: true, name: 'toybaco_ai_operation_store'
    add_foreign_key :toybaco_growth_draft_requests, :toybaco_growth_ai_operations, column: [:operation_id, :account_id],
                                                                                   primary_key: [:id, :account_id], on_delete: :cascade
    add_check_constraint :toybaco_growth_draft_requests, "state IN ('queued', 'running', 'completed', 'failed')", name: 'toybaco_draft_request_state'
  end
end
