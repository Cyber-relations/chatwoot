# frozen_string_literal: true

require_relative '../../lib/toybaco/durable_acceptance'

class CreateToybacoRenewalIngress < ActiveRecord::Migration[7.2]
  def up
    operations
    facts
    constraints
    Toybaco::DurableAcceptance.add_capability('renewal-ingress-v1') { |sql| execute sql }
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Signed renewal evidence must survive rollback'
  end

  private

  def operations
    create_table :toybaco_renewal_operations do |t|
      t.string :mode, :subscription_id, :customer_id, :invoice_id, null: false
      t.string :state, null: false, default: 'unverified'
      t.bigint :account_id, :first_fact_id
      t.datetime :first_failed_at, :due_at, :verified_at
      t.string :source_hash, :result
      t.timestamps
    end
    add_index :toybaco_renewal_operations, %i[mode subscription_id invoice_id], unique: true, name: 'renewal_operation_identity'
    add_index :toybaco_renewal_operations, %i[state due_at], name: 'renewal_operation_due'
  end

  def facts
    create_table :toybaco_renewal_invoice_facts do |t|
      t.bigint :billing_event_id, :renewal_operation_id, null: false
      t.string :event_id, :event_type, :mode, :subscription_id, :customer_id, :invoice_id, :payload_digest, null: false
      t.integer :attempt_count, null: false
      t.datetime :event_created_at, null: false
      t.timestamps
    end
    add_index :toybaco_renewal_invoice_facts, :billing_event_id, unique: true
    add_index :toybaco_renewal_invoice_facts, %i[mode event_id], unique: true, name: 'renewal_fact_event'
    add_index :toybaco_renewal_invoice_facts, %i[id renewal_operation_id], unique: true, name: 'renewal_fact_operation'
    add_foreign_key :toybaco_renewal_invoice_facts, :toybaco_billing_events, column: :billing_event_id
    add_foreign_key :toybaco_renewal_invoice_facts, :toybaco_renewal_operations, column: :renewal_operation_id
    add_foreign_key :toybaco_renewal_operations, :toybaco_renewal_invoice_facts,
                    column: %i[first_fact_id id], primary_key: %i[id renewal_operation_id], name: 'renewal_first_fact_operation'
  end

  def constraints
    add_check_constraint :toybaco_renewal_invoice_facts,
                         "mode IN ('test','live') AND event_type IN ('invoice.payment_failed','invoice.paid') " \
                         "AND attempt_count >= 0 AND (event_type <> 'invoice.payment_failed' OR attempt_count > 0) " \
                         'AND isfinite(event_created_at)', name: 'renewal_fact_shape'
    add_check_constraint :toybaco_renewal_operations,
                         "mode IN ('test','live') AND state IN " \
                         "('unverified','waiting_first','observed_failure','resolved_observation','outside_terms','attention') " \
                         'AND (account_id IS NULL OR account_id > 0)', name: 'renewal_operation_shape'
    add_check_constraint :toybaco_renewal_operations,
                         '(first_fact_id IS NULL AND first_failed_at IS NULL AND due_at IS NULL) OR ' \
                         '(first_fact_id IS NOT NULL AND first_failed_at IS NOT NULL AND due_at IS NOT NULL AND ' \
                         "isfinite(first_failed_at) AND due_at = first_failed_at + interval '604800 seconds')",
                         name: 'renewal_operation_deadline'
    add_check_constraint :toybaco_renewal_operations,
                         "state <> 'observed_failure' OR (account_id IS NOT NULL AND first_fact_id IS NOT NULL AND verified_at IS NOT NULL " \
                         'AND source_hash IS NOT NULL)', name: 'renewal_operation_verified'
  end
end
