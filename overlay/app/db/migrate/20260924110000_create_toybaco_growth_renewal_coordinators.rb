# frozen_string_literal: true

require_relative '../../lib/toybaco/durable_acceptance'

class CreateToybacoGrowthRenewalCoordinators < ActiveRecord::Migration[7.2]
  def up
    create_table :toybaco_growth_renewal_coordinators do |t|
      t.bigint :account_id, :renewal_operation_id, null: false
      t.string :operation_id, :receipt_hash, null: false
      t.string :phase, null: false, default: 'prepared'
      t.jsonb :receipt, null: false
      t.datetime :due_at, null: false
      t.timestamps null: false
    end
    add_index :toybaco_growth_renewal_coordinators, :renewal_operation_id, unique: true, name: 'renewal_coordinator_origin'
    add_index :toybaco_growth_renewal_coordinators, :operation_id, unique: true
    add_index :toybaco_growth_renewal_coordinators, %i[phase due_at], name: 'renewal_coordinator_phase'
    add_foreign_key :toybaco_growth_renewal_coordinators, :toybaco_renewal_operations, column: :renewal_operation_id
    add_check_constraint :toybaco_growth_renewal_coordinators,
                         "phase IN ('prepared','waiting','stop_recorded','attention') AND account_id > 0 AND " \
                         "operation_id ~ '^[0-9a-f]{64}$' AND receipt_hash ~ '^[0-9a-f]{64}$' AND jsonb_typeof(receipt) = 'object' AND " \
                         'isfinite(due_at) AND due_at <= created_at AND created_at <= updated_at', name: 'renewal_coordinator_shape'
    Toybaco::DurableAcceptance.add_capability('renewal-settlement-v1') { |sql| execute sql }
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Renewal stop preparation must survive rollback'
  end
end
