# frozen_string_literal: true

class CreateToybacoGrowthPaymentEvents < ActiveRecord::Migration[7.1]
  def change
    create_table :toybaco_growth_payment_events do |t|
      t.string :event_id, null: false
      t.string :action, null: false
      t.string :reference_id, null: false
      t.jsonb :snapshot, null: false, default: {}
      t.string :payload_digest, null: false
      t.string :state, null: false, default: 'pending'
      t.integer :attempts, null: false, default: 0
      t.integer :attempt_limit, null: false, default: 20
      t.jsonb :recovery_log, null: false, default: []
      t.datetime :next_attempt_at, null: false
      t.string :lease_token
      t.datetime :lease_expires_at
      t.string :result
      t.datetime :completed_at
      t.timestamps
    end
    add_receipt_constraints
  end

  private

  def add_receipt_constraints
    add_index :toybaco_growth_payment_events, :event_id, unique: true
    add_index :toybaco_growth_payment_events, [:state, :next_attempt_at], name: 'toybaco_payment_pending'
    add_check_constraint :toybaco_growth_payment_events, 'attempts >= 0', name: 'toybaco_payment_attempts_nonnegative'
  end
end
