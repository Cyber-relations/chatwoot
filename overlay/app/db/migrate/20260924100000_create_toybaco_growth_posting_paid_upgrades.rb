# frozen_string_literal: true

require_relative '../../lib/toybaco/durable_acceptance'

class CreateToybacoGrowthPostingPaidUpgrades < ActiveRecord::Migration[7.1]
  def up
    create_table :toybaco_growth_posting_paid_upgrades do |t|
      t.bigint :account_id, null: false
      t.string :operation_id, null: false
      t.jsonb :receipt, null: false
      t.string :state, null: false, default: 'pending'
      t.jsonb :postiz_receipt
      t.jsonb :application
      t.jsonb :applied_context
      t.string :applied_pointer_hash
      t.timestamps
    end
    add_constraints
    Toybaco::DurableAcceptance.add_capability('posting-paid-upgrade-v1') { |sql| execute sql }
  end

  def add_constraints
    add_index :toybaco_growth_posting_paid_upgrades, [:account_id, :operation_id], unique: true,
                                                                                   name: 'toybaco_posting_paid_upgrade_identity'
    pending = "state NOT IN ('ready','withdrawn')"
    add_index :toybaco_growth_posting_paid_upgrades, :account_id, unique: true,
                                                                  where: pending, name: 'toybaco_posting_paid_upgrade_pending'
    add_check_constraint :toybaco_growth_posting_paid_upgrades,
                         "account_id > 0 AND state IN ('pending','prepared','applied','active','ready','withdrawn') AND " \
                         "((state IN ('pending','prepared','withdrawn') AND application IS NULL AND applied_context IS NULL " \
                         "AND applied_pointer_hash IS NULL) OR (state IN ('applied','active','ready') AND application IS NOT NULL " \
                         'AND applied_context IS NOT NULL AND applied_pointer_hash IS NOT NULL))',
                         name: 'toybaco_posting_paid_upgrade_state'
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Posting paid upgrade history must survive rollback'
  end
end
