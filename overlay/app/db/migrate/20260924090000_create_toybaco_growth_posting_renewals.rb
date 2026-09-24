# frozen_string_literal: true

require_relative '../../lib/toybaco/durable_acceptance'

class CreateToybacoGrowthPostingRenewals < ActiveRecord::Migration[7.2]
  def up
    create_table :toybaco_growth_posting_renewals do |t|
      t.bigint :account_id, null: false
      t.string :request_id, :source_authority_id, :target_authority_id, :kind, :mode, :subscription_id, :invoice_id, null: false
      t.jsonb :receipt, null: false
      t.string :state, null: false, default: 'prepared'
      t.jsonb :postiz_receipt, :confirm_receipt
      t.string :rails_pointer_hash
      t.timestamps
    end
    add_index :toybaco_growth_posting_renewals, %i[account_id request_id], unique: true, name: 'posting_renewal_request'
    add_index :toybaco_growth_posting_renewals, %i[account_id mode subscription_id invoice_id kind], unique: true, name: 'posting_renewal_invoice'
    add_index :toybaco_growth_posting_renewals, %i[account_id target_authority_id], unique: true, name: 'posting_renewal_target'
    add_index :toybaco_growth_posting_renewals, :account_id, unique: true,
                                                             where: "state IN ('transferring','applied')", name: 'posting_renewal_inflight'
    add_check_constraint :toybaco_growth_posting_renewals, shape, name: 'posting_renewal_shape'
    Toybaco::DurableAcceptance.add_capability('posting-renewal-v1') { |sql| execute sql }
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Renewal authority and handoff receipts must be retained'
  end

  private

  def shape
    <<~SQL.squish
      account_id > 0 AND kind IN ('renewal_grace','renewal_paid') AND mode IN ('test','live')
      AND state IN ('prepared','transferring','applied','ready')
      AND request_id ~ '^[0-9a-f]{64}$' AND source_authority_id ~ '^[0-9a-f]{64}$'
      AND target_authority_id ~ '^[0-9a-f]{64}$' AND source_authority_id <> target_authority_id
      AND jsonb_typeof(receipt) = 'object'
      AND (state IN ('prepared','transferring') OR (postiz_receipt IS NOT NULL AND rails_pointer_hash IS NOT NULL AND rails_pointer_hash ~ '^[0-9a-f]{64}$'))
      AND (state <> 'ready' OR confirm_receipt IS NOT NULL)
    SQL
  end
end
