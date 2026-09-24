# frozen_string_literal: true

class CreateToybacoGrowthManagedAuto < ActiveRecord::Migration[7.2]
  def change
    create_installations
    create_commands
    create_requests
  end

  private

  def create_installations
    create_table :toybaco_growth_auto_installations do |t|
      t.bigint :account_id, null: false
      t.bigint :inbox_id, null: false
      t.bigint :bot_id, null: false
      t.bigint :actor_id, null: false
      t.string :request_id, null: false
      t.bigint :generation, null: false, default: 1
      t.bigint :message_floor_id, null: false, default: 0
      t.uuid :epoch, null: false
      t.string :state, null: false, default: 'draft'
      t.timestamps
    end
    %i[account_id inbox_id bot_id].each { |key| add_index :toybaco_growth_auto_installations, key, unique: true }
    add_check_constraint :toybaco_growth_auto_installations,
                         "generation > 0 AND message_floor_id >= 0 AND state IN ('draft', 'auto', 'stopping', 'stopped')",
                         name: 'toybaco_auto_installation_state'
  end

  def create_commands
    create_table :toybaco_growth_auto_commands do |t|
      t.bigint :account_id, null: false
      t.bigint :installation_id, null: false
      t.bigint :actor_id, null: false
      t.string :request_id, null: false
      t.string :request_hash, null: false
      t.timestamps
    end
    add_index :toybaco_growth_auto_commands, [:account_id, :request_id], unique: true, name: 'toybaco_auto_command_identity'
  end

  def create_requests
    create_table :toybaco_growth_auto_requests do |t|
      # Keep minimal unresolved records even when a business row disappears.
      t.bigint :account_id, null: false
      t.bigint :inbox_id, null: false
      t.bigint :installation_id, null: false
      t.bigint :generation, null: false
      t.uuid :epoch, null: false
      t.bigint :message_id, null: false
      t.bigint :conversation_id, null: false
      t.bigint :operation_id
      t.string :state, null: false, default: 'queued'
      t.string :reason
      t.datetime :started_at
      t.datetime :terminal_at
      t.datetime :enqueue_after, null: false
      t.timestamps
    end
    create_request_indexes
    add_check_constraint :toybaco_growth_auto_requests, request_constraint, name: 'toybaco_auto_request_state'
  end

  def create_request_indexes
    add_index :toybaco_growth_auto_requests, [:account_id, :message_id], unique: true, name: 'toybaco_auto_request_identity'
    add_index :toybaco_growth_auto_requests, :operation_id, unique: true
    add_index :toybaco_growth_auto_requests, [:account_id, :state], name: 'toybaco_auto_request_pending'
    add_index :toybaco_growth_auto_requests, [:state, :enqueue_after], name: 'toybaco_auto_request_queue'
  end

  def request_constraint
    <<~SQL.squish
      generation > 0 AND (
        (state = 'queued' AND started_at IS NULL AND terminal_at IS NULL AND operation_id IS NULL) OR
        (state IN ('started', 'uncertain') AND started_at IS NOT NULL AND terminal_at IS NULL AND operation_id IS NOT NULL) OR
        (state IN ('completed', 'handoff') AND started_at IS NOT NULL AND terminal_at IS NOT NULL AND operation_id IS NOT NULL) OR
        (state = 'cancelled' AND terminal_at IS NOT NULL)
      )
    SQL
  end
end
