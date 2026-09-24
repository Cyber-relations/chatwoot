# frozen_string_literal: true

require_relative '../../lib/toybaco/durable_acceptance'

class CreateToybacoGrowthRenewalDispatches < ActiveRecord::Migration[7.2]
  def up
    create_table :toybaco_growth_renewal_dispatches do |t|
      t.bigint :renewal_operation_id, :requested_fact_id, null: false
      t.bigint :processed_fact_id, null: false, default: 0
      t.string :state, null: false, default: 'pending'
      t.string :phase, null: false, default: 'received'
      t.string :result, :lease_token
      t.integer :attempts, null: false, default: 0
      t.datetime :deadline_at, :next_attempt_at, :next_enqueue_at, null: false
      t.datetime :due_at, :lease_expires_at
      t.jsonb :grace_context, :paid_context
      t.timestamps null: false
    end
    constraints
    Toybaco::DurableAcceptance.add_capability('renewal-dispatch-v1') { |sql| execute sql }
  end

  def constraints
    add_index :toybaco_growth_renewal_dispatches, :renewal_operation_id, unique: true
    add_index :toybaco_growth_renewal_dispatches, [:state, :next_attempt_at], name: 'renewal_dispatch_due'
    add_foreign_key :toybaco_growth_renewal_dispatches, :toybaco_renewal_operations, column: :renewal_operation_id
    add_foreign_key :toybaco_growth_renewal_dispatches, :toybaco_renewal_invoice_facts, column: :requested_fact_id
    add_check_constraint :toybaco_growth_renewal_dispatches,
                         "state IN ('pending','running','idle','attention') AND " \
                         "phase IN ('received','grace_ready','paid_ready','due_waiting','provider_closed','free_completed') AND " \
                         'processed_fact_id >= 0 AND requested_fact_id > 0 AND attempts >= 0 AND ' \
                         "((state = 'running') = (lease_token IS NOT NULL AND lease_expires_at IS NOT NULL)) AND " \
                         "(grace_context IS NULL OR jsonb_typeof(grace_context) = 'object') AND " \
                         "(paid_context IS NULL OR jsonb_typeof(paid_context) = 'object') AND created_at <= updated_at",
                         name: 'renewal_dispatch_shape'
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Accepted renewal dispatches must survive rollback'
  end
end
