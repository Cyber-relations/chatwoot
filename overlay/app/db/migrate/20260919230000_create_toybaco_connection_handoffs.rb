# frozen_string_literal: true

class CreateToybacoConnectionHandoffs < ActiveRecord::Migration[7.1]
  def change
    create_table :toybaco_connection_handoffs do |t|
      identity_fields(t)
      link_fields(t)
      verification_fields(t)
      t.timestamps
    end
    indexes
    add_check_constraint :toybaco_connection_handoffs, "state IN ('issued', 'claimed', 'completed', 'revoked')", name: 'toybaco_handoff_state'
    add_check_constraint :toybaco_connection_handoffs, 'verification_attempts BETWEEN 0 AND 5 AND verification_send_count BETWEEN 0 AND 3',
                         name: 'toybaco_handoff_verification_limits'
  end

  private

  def identity_fields(table)
    table.references :account, null: false, foreign_key: { on_delete: :cascade }
    table.bigint :creator_id, null: false
    table.uuid :public_id, null: false
    table.uuid :request_id, null: false
    table.string :request_digest, null: false, limit: 64
    table.string :provider, null: false
    table.string :target_key, null: false
    table.bigint :inbox_id
    table.string :state, null: false, default: 'issued'
    table.datetime :expires_at, null: false
    table.datetime :completed_at
    table.bigint :result_inbox_id
  end

  def link_fields(table)
    table.string :token_digest, limit: 64
    table.text :encrypted_token
    table.string :recipient_digest, null: false, limit: 64
    table.text :encrypted_recipient
    table.string :claim_digest, limit: 64
    table.datetime :claimed_at
  end

  def verification_fields(table)
    table.string :verification_digest, limit: 64
    table.uuid :verification_revision
    table.string :verification_browser_digest, limit: 64
    table.datetime :verification_expires_at
    table.datetime :verification_requested_at
    table.integer :verification_attempts, null: false, default: 0
    table.integer :verification_send_count, null: false, default: 0
    table.text :encrypted_verification
    table.string :delivery_state
    table.datetime :delivery_attempted_at
  end

  def indexes
    add_index :toybaco_connection_handoffs, :public_id, unique: true
    add_index :toybaco_connection_handoffs, [:account_id, :request_id], unique: true, name: 'index_toybaco_handoff_request'
    add_index :toybaco_connection_handoffs, [:account_id, :target_key, :state], name: 'index_toybaco_handoff_target'
    add_index :toybaco_connection_handoffs, [:state, :expires_at], name: 'index_toybaco_handoff_expiry'
  end
end
