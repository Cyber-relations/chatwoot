# frozen_string_literal: true

class CreateToybacoGrowthPackOrders < ActiveRecord::Migration[7.2]
  def change
    create_table :toybaco_growth_pack_orders do |t|
      t.bigint :account_id, null: false
      t.bigint :owner_id, null: false
      t.string :request_key, null: false
      t.string :nonce, null: false
      t.string :state, null: false, default: 'prepared'
      t.jsonb :payload, null: false, default: {}
      t.string :session_id
      t.string :payment_intent_id
      t.string :event_id
      t.datetime :paid_at
      t.datetime :refunded_at
      t.timestamps
    end
    add_index :toybaco_growth_pack_orders, [:account_id, :request_key], unique: true, name: 'toybaco_pack_request_once'
    add_index :toybaco_growth_pack_orders, :nonce, unique: true
    add_index :toybaco_growth_pack_orders, :session_id, unique: true
    add_index :toybaco_growth_pack_orders, :payment_intent_id, unique: true
    add_index :toybaco_growth_pack_orders, [:account_id, :state]
  end
end
