# frozen_string_literal: true

class CreateToybacoGrowthFreeReturns < ActiveRecord::Migration[7.1]
  def change
    create_table :toybaco_growth_free_returns do |t|
      t.bigint :account_id, null: false
      t.string :transition_id, null: false
      t.jsonb :receipt, null: false
      t.timestamps
    end
    add_foreign_key :toybaco_growth_free_returns, :accounts, on_delete: :cascade
    add_index :toybaco_growth_free_returns, [:account_id, :transition_id], unique: true, name: 'toybaco_free_return_identity'
  end
end
