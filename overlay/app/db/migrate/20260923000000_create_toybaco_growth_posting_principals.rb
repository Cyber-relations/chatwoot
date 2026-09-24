# frozen_string_literal: true

class CreateToybacoGrowthPostingPrincipals < ActiveRecord::Migration[7.1]
  def change
    create_table :toybaco_growth_posting_principals do |t|
      # No credential or identity value; retained across membership deletion.
      t.bigint :account_id, null: false
      t.bigint :user_id, null: false
      t.bigint :generation, null: false
      t.string :epoch, null: false
      t.timestamps
    end
    add_index :toybaco_growth_posting_principals, [:account_id, :user_id], unique: true, name: 'toybaco_posting_principal_identity'
    add_check_constraint :toybaco_growth_posting_principals,
                         "account_id > 0 AND user_id > 0 AND generation > 0 AND epoch ~ '^[0-9a-f]{64}$'",
                         name: 'toybaco_posting_principal_valid'
  end
end
