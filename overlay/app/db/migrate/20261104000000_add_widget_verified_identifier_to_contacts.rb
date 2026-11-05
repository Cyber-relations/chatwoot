# frozen_string_literal: true

class AddWidgetVerifiedIdentifierToContacts < ActiveRecord::Migration[7.0]
  def change
    # Intentionally no backfill: legacy identifiers and hmac_verified links
    # cannot prove that an unsigned session never shared the contact.
    add_column :contacts, :toybaco_widget_verified_identifier, :string
  end
end
