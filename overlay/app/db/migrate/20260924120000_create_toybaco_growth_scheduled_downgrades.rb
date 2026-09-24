# frozen_string_literal: true

require_relative '../../lib/toybaco/durable_acceptance'

class CreateToybacoGrowthScheduledDowngrades < ActiveRecord::Migration[7.2]
  def up
    create_table :toybaco_growth_scheduled_downgrades do |t|
      t.bigint :account_id, :renewal_operation_id, null: false
      t.bigint :grant_id
      t.jsonb :receipt, null: false
      t.string :receipt_hash, null: false
      t.jsonb :recovery
      t.string :recovery_hash
      t.timestamps null: false
    end
    add_index :toybaco_growth_scheduled_downgrades, :renewal_operation_id, unique: true, name: 'scheduled_downgrade_origin'
    add_index :toybaco_growth_scheduled_downgrades, :grant_id, unique: true
    add_index :toybaco_growth_scheduled_downgrades, :account_id
    add_foreign_key :toybaco_growth_scheduled_downgrades, :toybaco_renewal_operations, column: :renewal_operation_id
    add_check_constraint :toybaco_growth_scheduled_downgrades,
                         "account_id > 0 AND jsonb_typeof(receipt) = 'object' AND receipt_hash ~ '^[0-9a-f]{64}$' AND " \
                         "((recovery IS NULL AND recovery_hash IS NULL) OR (jsonb_typeof(recovery) = 'object' AND " \
                         "recovery_hash ~ '^[0-9a-f]{64}$')) AND created_at <= updated_at", name: 'scheduled_downgrade_shape'
    Toybaco::DurableAcceptance.add_capability('scheduled-downgrade-grace-v1') { |sql| execute sql }
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Scheduled downgrade grace must survive rollback'
  end
end
