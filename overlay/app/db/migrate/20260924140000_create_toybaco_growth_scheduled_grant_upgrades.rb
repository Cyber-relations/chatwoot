# frozen_string_literal: true

require_relative '../../lib/toybaco/durable_acceptance'

class CreateToybacoGrowthScheduledGrantUpgrades < ActiveRecord::Migration[7.2]
  def up
    create_table :toybaco_growth_scheduled_grant_upgrades do |t|
      t.bigint :account_id, :scheduled_downgrade_id, :grant_id, null: false
      t.string :operation_id, :parent_hash, :receipt_hash, null: false
      t.jsonb :receipt, null: false
      t.timestamps null: false
    end
    add_index :toybaco_growth_scheduled_grant_upgrades, :operation_id, unique: true, name: 'scheduled_grant_upgrade_operation'
    add_index :toybaco_growth_scheduled_grant_upgrades, [:scheduled_downgrade_id, :parent_hash], unique: true, name: 'scheduled_grant_upgrade_parent'
    add_index :toybaco_growth_scheduled_grant_upgrades, :grant_id
    add_foreign_key :toybaco_growth_scheduled_grant_upgrades, :toybaco_growth_scheduled_downgrades, column: :scheduled_downgrade_id
    add_check_constraint :toybaco_growth_scheduled_grant_upgrades,
                         "account_id > 0 AND grant_id > 0 AND jsonb_typeof(receipt) = 'object' AND " \
                         "operation_id ~ '^[0-9a-f]{64}$' AND parent_hash ~ '^[0-9a-f]{64}$' AND receipt_hash ~ '^[0-9a-f]{64}$' AND " \
                         'created_at = updated_at', name: 'scheduled_grant_upgrade_shape'
    Toybaco::DurableAcceptance.add_capability('scheduled-grant-upgrade-v1') { |sql| execute sql }
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Paid grant continuation must survive rollback'
  end
end
