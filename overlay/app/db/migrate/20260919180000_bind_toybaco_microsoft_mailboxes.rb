# frozen_string_literal: true

class BindToybacoMicrosoftMailboxes < ActiveRecord::Migration[7.1]
  def change
    add_index :channel_email, "(provider_config->'toybaco_microsoft'->>'subject_id')",
              unique: true, name: 'index_toybaco_microsoft_mailbox_identity',
              where: "provider = 'microsoft' AND provider_config ? 'toybaco_microsoft'"
  end
end
