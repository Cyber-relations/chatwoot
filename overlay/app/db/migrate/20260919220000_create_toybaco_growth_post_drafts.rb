# frozen_string_literal: true

class CreateToybacoGrowthPostDrafts < ActiveRecord::Migration[7.1]
  def change
    create_table :toybaco_growth_post_drafts do |t|
      t.bigint :account_id, null: false
      t.bigint :user_id, null: false
      t.bigint :operation_id, null: false
      t.string :organization_id, null: false
      t.string :editor_id, null: false
      t.string :draft_digest, null: false
      t.string :facts_revision, null: false
      t.string :state, null: false, default: 'queued'
      t.text :encrypted_input
      t.text :encrypted_result
      t.string :error_code
      t.datetime :expires_at, null: false
      t.datetime :result_expires_at
      t.timestamps
    end
    add_draft_constraints
  end

  private

  def add_draft_constraints
    add_foreign_key :toybaco_growth_post_drafts, :accounts, on_delete: :cascade
    add_foreign_key :toybaco_growth_post_drafts, :toybaco_growth_ai_operations, column: :operation_id, on_delete: :cascade
    add_index :toybaco_growth_post_drafts, :operation_id, unique: true
    add_index :toybaco_growth_post_drafts, [:account_id, :user_id, :editor_id], name: 'toybaco_post_draft_editor'
    add_index :toybaco_growth_post_drafts, [:state, :expires_at]
  end
end
