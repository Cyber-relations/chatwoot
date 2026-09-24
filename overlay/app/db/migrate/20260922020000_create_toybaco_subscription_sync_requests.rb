# frozen_string_literal: true

class CreateToybacoSubscriptionSyncRequests < ActiveRecord::Migration[7.1]
  def change
    create_table :toybaco_subscription_sync_requests do |t|
      t.string :subscription_id, null: false
      t.string :mode, null: false
      t.bigint :account_id
      t.string :state, null: false, default: 'pending'
      t.bigint :requested_revision, null: false, default: 1
      t.bigint :completed_revision, null: false, default: 0
      t.integer :attempts, null: false, default: 0
      t.datetime :deadline_at, null: false
      t.datetime :next_attempt_at, null: false
      t.datetime :next_enqueue_at, null: false
      t.string :result
      t.datetime :completed_at
      t.timestamps
    end
    add_lookup_indexes
    add_check_constraint :toybaco_subscription_sync_requests,
                         'requested_revision > 0 AND completed_revision >= 0 AND completed_revision <= requested_revision AND attempts >= 0',
                         name: 'toybaco_subscription_sync_counters'
  end

  private

  def add_lookup_indexes
    add_index :toybaco_subscription_sync_requests, [:mode, :subscription_id], unique: true, name: 'toybaco_subscription_sync_identity'
    add_index :toybaco_subscription_sync_requests, [:state, :next_attempt_at], name: 'toybaco_subscription_sync_due'
  end
end
