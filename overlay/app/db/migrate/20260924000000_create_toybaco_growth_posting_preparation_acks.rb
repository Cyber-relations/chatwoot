# frozen_string_literal: true

class CreateToybacoGrowthPostingPreparationAcks < ActiveRecord::Migration[7.0]
  def change
    create_table :toybaco_growth_posting_preparation_acks do |t|
      t.bigint :account_id, null: false
      t.string :request_id, null: false, limit: 64
      t.jsonb :receipt, null: false
      t.timestamps null: false
    end
    add_index :toybaco_growth_posting_preparation_acks, [:account_id, :request_id], unique: true, name: 'toybaco_posting_preparation_ack_identity'
  end
end
