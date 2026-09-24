# frozen_string_literal: true

class CreateToybacoBillingEvents < ActiveRecord::Migration[7.1]
  def change
    create_table :toybaco_billing_events do |t|
      t.string :event_id, :mode, :action, :reference_id, :payload_digest, null: false
      t.jsonb :snapshot, null: false, default: {}
      t.string :state, null: false, default: 'pending'
      t.integer :attempts, null: false, default: 0
      t.integer :attempt_limit, null: false, default: 48
      t.jsonb :recovery_log, null: false, default: []
      t.datetime :deadline_at, :next_attempt_at, null: false
      t.string :lease_token, :result
      t.datetime :lease_expires_at, :completed_at
      t.bigint :subscription_sync_request_id, :requested_revision
      t.timestamps
    end
    add_receipt_constraints
  end

  private

  def add_receipt_constraints
    add_index :toybaco_billing_events, [:mode, :event_id], unique: true
    add_index :toybaco_billing_events, [:state, :next_attempt_at]
    add_foreign_key :toybaco_billing_events, :toybaco_subscription_sync_requests, column: :subscription_sync_request_id
    add_check_constraint :toybaco_billing_events, "mode IN ('test', 'live') AND attempts >= 0 AND attempt_limit > 0",
                         name: 'toybaco_billing_counters'
    add_check_constraint :toybaco_billing_events,
                         '(subscription_sync_request_id IS NULL AND requested_revision IS NULL) OR ' \
                         "(action = 'subscription_notice' AND subscription_sync_request_id IS NOT NULL " \
                         'AND requested_revision IS NOT NULL AND requested_revision > 0)',
                         name: 'toybaco_billing_revision_binding'
  end
end
