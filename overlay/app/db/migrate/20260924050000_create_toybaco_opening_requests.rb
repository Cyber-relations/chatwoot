# frozen_string_literal: true

class CreateToybacoOpeningRequests < ActiveRecord::Migration[7.1]
  def change
    create_table :toybaco_opening_requests do |t|
      t.string :mode, :session_id, null: false
      t.string :state, null: false, default: 'pending'
      t.integer :attempts, null: false, default: 0
      t.datetime :deadline_at, null: false
      t.string :subscription_id, :contract_digest
      t.bigint :account_id, :owner_id
      t.string :onboarding_state, null: false, default: 'pending'
      t.datetime :account_ready_at
      t.timestamps
    end
    add_index :toybaco_opening_requests, [:mode, :session_id], unique: true
    add_index :toybaco_opening_requests, [:mode, :subscription_id], unique: true
    add_constraints
  end

  private

  def add_constraints
    add_check_constraint :toybaco_opening_requests, "mode IN ('test', 'live') AND state IN ('pending', 'account_ready', 'attention') " \
                                                    'AND attempts BETWEEN 0 AND 48',
                         name: 'toybaco_opening_state'
    add_check_constraint :toybaco_opening_requests,
                         "(state IN ('pending', 'attention') AND account_id IS NULL AND owner_id IS NULL AND subscription_id IS NULL " \
                         'AND contract_digest IS NULL AND account_ready_at IS NULL) OR ' \
                         "(state = 'account_ready' AND account_id IS NOT NULL AND account_id > 0 AND owner_id IS NOT NULL AND owner_id > 0 " \
                         'AND subscription_id IS NOT NULL AND contract_digest IS NOT NULL AND account_ready_at IS NOT NULL)',
                         name: 'toybaco_opening_binding'
    add_reference :toybaco_billing_events, :opening_request, foreign_key: { to_table: :toybaco_opening_requests }
    add_check_constraint :toybaco_billing_events,
                         "opening_request_id IS NULL OR (action = 'opening_checkout' AND subscription_sync_request_id IS NULL)",
                         name: 'toybaco_billing_opening_binding'
  end
end
