# frozen_string_literal: true

class CreateToybacoGrowthInboxReleases < ActiveRecord::Migration[7.0]
  def change
    create_table :toybaco_growth_inbox_releases do |t|
      t.bigint :account_id, null: false
      t.string :request_id, null: false
      t.jsonb :receipt, null: false
      t.timestamps
    end
    add_foreign_key :toybaco_growth_inbox_releases, :accounts, on_delete: :cascade
    add_index :toybaco_growth_inbox_releases, [:account_id, :request_id], unique: true, name: 'toybaco_inbox_release_identity'
  end
end
