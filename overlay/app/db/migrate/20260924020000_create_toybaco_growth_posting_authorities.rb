# frozen_string_literal: true

class CreateToybacoGrowthPostingAuthorities < ActiveRecord::Migration[7.1]
  def up
    create_authorities
    create_current_pointers
    add_column :toybaco_growth_posting_executions, :pending_evidence_hash, :string
    add_column :toybaco_growth_posting_executions, :uncertain_evidence_hash, :string
    remove_check_constraint :toybaco_growth_posting_executions, name: 'toybaco_posting_execution_state'
    add_check_constraint :toybaco_growth_posting_executions, execution_constraint, name: 'toybaco_posting_execution_state'
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Posting authority and unresolved execution receipts must be retained'
  end

  private

  def create_authorities
    create_table :toybaco_growth_posting_authorities do |t|
      t.bigint :account_id, null: false
      t.string :authority_id, null: false
      t.string :preparation_request_id, null: false
      t.jsonb :receipt, null: false
      t.string :state, null: false, default: 'pending'
      t.jsonb :postiz_receipt
      t.timestamps
    end
    add_index :toybaco_growth_posting_authorities, [:account_id, :authority_id], unique: true,
                                                                                 name: 'toybaco_posting_authority_identity'
    add_check_constraint :toybaco_growth_posting_authorities,
                         "account_id > 0 AND state IN ('pending', 'active', 'stale')", name: 'toybaco_posting_authority_state'
  end

  def create_current_pointers
    create_table :toybaco_growth_posting_authority_currents, id: false do |t|
      t.bigint :account_id, null: false, primary_key: true
      t.bigint :generation, null: false
      t.string :epoch, null: false
      t.string :authority_id
      t.timestamps
    end
    add_check_constraint :toybaco_growth_posting_authority_currents,
                         'account_id > 0 AND generation > 0', name: 'toybaco_posting_authority_current_generation'
  end

  def execution_constraint
    <<~SQL.squish
      account_id > 0
      AND (uncertain_evidence_hash IS NULL OR (COALESCE(request->>'version', '') = '3'
        AND uncertain_evidence_hash ~ '^[0-9a-f]{64}$' AND state IN ('uncertain', 'pending', 'completed')))
      AND (COALESCE(request->>'version', '') != '3' OR state != 'uncertain' OR uncertain_evidence_hash IS NOT NULL)
      AND (pending_evidence_hash IS NULL OR (COALESCE(request->>'version', '') = '3' AND pending_evidence_hash ~ '^[0-9a-f]{64}$'))
      AND (
        (state = 'prepared' AND started_at IS NULL AND terminal_at IS NULL AND outcome IS NULL AND evidence_hash IS NULL) OR
        (state IN ('started', 'uncertain') AND started_at IS NOT NULL AND terminal_at IS NULL AND outcome IS NULL AND evidence_hash IS NULL) OR
        (state = 'pending' AND COALESCE(request->>'version', '') = '3' AND COALESCE(request->>'step', '') = 'MAIN'
          AND started_at IS NOT NULL AND terminal_at IS NULL AND outcome IS NULL AND evidence_hash IS NOT NULL
          AND pending_evidence_hash IS NOT NULL AND pending_evidence_hash = evidence_hash) OR
        (state = 'cancelled' AND started_at IS NULL AND terminal_at IS NOT NULL AND outcome IS NULL AND evidence_hash IS NULL) OR
        (state = 'completed' AND started_at IS NOT NULL AND terminal_at IS NOT NULL AND evidence_hash IS NOT NULL AND outcome IS NOT NULL
          AND (outcome IN ('published', 'rejected') OR (COALESCE(request->>'version', '') = '3'
            AND (outcome = 'not_sent' OR (outcome = 'pending' AND COALESCE(request->>'step', '') = 'FINALIZE'
              AND pending_evidence_hash IS NOT NULL AND pending_evidence_hash = evidence_hash)))))
      )
    SQL
  end
end
