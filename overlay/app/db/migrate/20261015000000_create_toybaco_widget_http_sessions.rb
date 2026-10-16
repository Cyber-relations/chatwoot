# frozen_string_literal: true

class CreateToybacoWidgetHttpSessions < ActiveRecord::Migration[7.0]
  def up
    create_sessions
    create_handoffs
    create_indexes
  end

  def create_sessions
    create_table :toybaco_widget_session_records do |t|
      t.references :contact_inbox, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :inbox_id, null: false
      t.string :secret_digest, null: false
      t.string :previous_secret_digest
      t.datetime :rotated_at, null: false
      t.string :link_digest, null: false
      t.string :bootstrap_digest, null: false
      t.datetime :bootstrap_expires_at, null: false
      t.datetime :expires_at, null: false
      t.datetime :persisted_at
      t.datetime :revoked_at
      t.timestamps
    end
  end

  def create_handoffs
    create_table :toybaco_widget_handoffs do |t|
      t.references(
        :widget_session_record,
        null: false,
        foreign_key: { to_table: :toybaco_widget_session_records, on_delete: :cascade },
        index: { name: 'index_toybaco_handoffs_session' }
      )
      t.string :code_digest, null: false
      t.string :kind, null: false
      t.string :link_digest, null: false
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.bigint :consumed_session_id
      t.string :consume_intent_digest
      t.string :cookie_digest
      t.datetime :cookie_expires_at
      t.timestamps
    end
  end

  def create_indexes
    add_index :toybaco_widget_session_records, :secret_digest, unique: true
    add_index :toybaco_widget_session_records, :bootstrap_digest, unique: true, name: 'index_toybaco_widget_sessions_bootstrap'
    add_index :toybaco_widget_session_records, :expires_at
    add_index :toybaco_widget_handoffs, :code_digest, unique: true
    add_index :toybaco_widget_handoffs, [:expires_at, :cookie_expires_at], name: 'index_toybaco_handoffs_expiry'
  end

  def down
    # Rolling back the image must preserve visitor continuity and consumed grants.
    raise ActiveRecord::IrreversibleMigration, 'Preserve Widget sessions and consumed handoff fences'
  end
end
