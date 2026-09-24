# frozen_string_literal: true

class CreateToybacoGrowthPostingPreparations < ActiveRecord::Migration[7.0]
  def change
    create_table :toybaco_growth_posting_preparations do |t|
      t.bigint :account_id, null: false
      t.string :request_id, null: false
      t.jsonb :receipt, null: false
      t.timestamps
    end
    add_index :toybaco_growth_posting_preparations, [:account_id, :request_id], unique: true, name: 'toybaco_posting_preparation_identity'
  end
end
