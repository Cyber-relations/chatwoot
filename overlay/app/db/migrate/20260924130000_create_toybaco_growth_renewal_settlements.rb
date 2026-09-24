# frozen_string_literal: true

require_relative '../../lib/toybaco/durable_acceptance'

class CreateToybacoGrowthRenewalSettlements < ActiveRecord::Migration[7.2]
  def up
    create_table :toybaco_growth_renewal_settlements do |t|
      t.bigint :account_id, :coordinator_id, null: false
      t.string :operation_id, :receipt_hash, null: false
      t.string :phase, null: false, default: 'prepared'
      t.jsonb :receipt, null: false
      t.timestamps null: false
    end
    add_index :toybaco_growth_renewal_settlements, :coordinator_id, unique: true
    add_index :toybaco_growth_renewal_settlements, :operation_id, unique: true
    add_foreign_key :toybaco_growth_renewal_settlements, :toybaco_growth_renewal_coordinators, column: :coordinator_id
    add_check_constraint :toybaco_growth_renewal_settlements,
                         "phase IN ('prepared','invoice_voided','provider_closed','payment_review','free_completed') AND account_id > 0 AND " \
                         "operation_id ~ '^[0-9a-f]{64}$' AND receipt_hash ~ '^[0-9a-f]{64}$' AND jsonb_typeof(receipt) = 'object' AND " \
                         'created_at <= updated_at', name: 'renewal_settlement_shape'
    expand_parent_shape
    Toybaco::DurableAcceptance.add_capability('renewal-provider-settlement-v1') { |sql| execute sql }
  end

  def expand_parent_shape
    remove_check_constraint :toybaco_growth_renewal_coordinators, name: 'renewal_coordinator_shape'
    add_check_constraint :toybaco_growth_renewal_coordinators,
                         "phase IN ('prepared','waiting','stop_recorded','attention','free_completed') AND account_id > 0 AND " \
                         "operation_id ~ '^[0-9a-f]{64}$' AND receipt_hash ~ '^[0-9a-f]{64}$' AND jsonb_typeof(receipt) = 'object' AND " \
                         'isfinite(due_at) AND due_at <= created_at AND created_at <= updated_at', name: 'renewal_coordinator_shape'
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Provider settlement checkpoints must survive rollback'
  end
end
