# frozen_string_literal: true

class CreateToybacoSupportReports < ActiveRecord::Migration[7.1]
  def change
    create_table :toybaco_support_reports do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :assignee_id, null: false
      t.uuid :request_id, null: false
      t.string :category, null: false
      t.string :article_id, null: false, default: ''
      t.string :knowledge_version, null: false
      t.string :state, null: false, default: 'received'
      t.string :resolution
      t.jsonb :diagnostics, null: false, default: []
      t.datetime :diagnostics_expires_at, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end
    indexes
    add_check_constraint :toybaco_support_reports, "state IN ('received', 'reviewing', 'resolved')", name: 'tb_support_state'
  end

  private

  def indexes
    add_index :toybaco_support_reports, %i[account_id user_id request_id], unique: true, name: 'index_tb_support_request'
    add_index :toybaco_support_reports, %i[category state created_at], name: 'index_tb_support_queue'
    add_index :toybaco_support_reports, :expires_at
    add_index :toybaco_support_reports, :diagnostics_expires_at
  end
end
