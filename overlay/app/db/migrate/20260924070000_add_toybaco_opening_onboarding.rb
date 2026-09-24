# frozen_string_literal: true

require_relative '../../lib/toybaco/durable_acceptance'

class AddToybacoOpeningOnboarding < ActiveRecord::Migration[7.1]
  def up
    setup_columns
    notice_table
    notice_constraints
    Toybaco::DurableAcceptance.extend_source('opening-ingress-v1', 'toybaco_opening_notices') { |sql| execute sql }
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Opening delivery history must survive rollback'
  end

  private

  def setup_columns
    change_table :toybaco_opening_requests, bulk: true do |t|
      t.string :industry
      t.string :industry_state, null: false, default: 'pending'
      t.string :inbox_state, null: false, default: 'pending'
      t.bigint :inbox_id
      t.integer :onboarding_attempts, null: false, default: 0
      t.datetime :onboarding_next_at
    end
    add_check_constraint :toybaco_opening_requests, "industry_state IN ('pending','applied','not_selected')", name: 'opening_industry_state'
    add_check_constraint :toybaco_opening_requests, "inbox_state IN ('pending','ready','blocked')", name: 'opening_inbox_state'
    add_check_constraint :toybaco_opening_requests, 'onboarding_attempts BETWEEN 0 AND 48', name: 'opening_onboarding_attempts'
    add_check_constraint :toybaco_opening_requests, "onboarding_state IN ('pending','ready','attention')", name: 'opening_onboarding_state'
    add_check_constraint :toybaco_opening_requests, "(inbox_state = 'ready') = (inbox_id IS NOT NULL)", name: 'opening_inbox_binding'
  end

  def notice_table
    create_table :toybaco_opening_notices do |t|
      t.references :opening_request, null: false, foreign_key: { to_table: :toybaco_opening_requests, on_delete: :restrict }
      t.string :request_id, null: false
      t.bigint :actor_id, null: false
      t.string :state, null: false, default: 'queued'
      t.datetime :attempted_at
      t.datetime :finished_at
      t.datetime :retain_until, null: false
      t.timestamps
    end
  end

  def notice_constraints
    add_index :toybaco_opening_notices, %i[opening_request_id request_id], unique: true, name: 'opening_notice_request'
    add_index :toybaco_opening_notices, :opening_request_id, unique: true,
                                                             where: "state IN ('queued','dispatching')", name: 'opening_notice_pending'
    add_check_constraint :toybaco_opening_notices, "state IN ('queued','dispatching','attempted','uncertain','cancelled')",
                         name: 'opening_notice_state'
    add_check_constraint :toybaco_opening_notices, 'actor_id > 0 AND retain_until > created_at', name: 'opening_notice_actor_retention'
    add_check_constraint :toybaco_opening_notices,
                         "(state = 'queued' AND attempted_at IS NULL AND finished_at IS NULL) OR " \
                         "(state = 'dispatching' AND attempted_at IS NOT NULL AND finished_at IS NULL) OR " \
                         "(state IN ('attempted','uncertain') AND attempted_at IS NOT NULL AND finished_at IS NOT NULL) OR " \
                         "(state = 'cancelled' AND finished_at IS NOT NULL)", name: 'opening_notice_times'
  end
end
