# frozen_string_literal: true

class EnsureToybacoJapaneseLocaleDefault < ActiveRecord::Migration[7.1]
  def up
    # Loading the newer upstream schema marks the older Toybaco locale migration
    # as applied, although that schema still defaults to English. Restore only
    # the column default; preserve every existing account and user preference.
    change_column_default :accounts, :locale, 7
  end

  def down
    # The earlier Toybaco migration also requires Japanese as the default.
    # Rolling back this repair must not undo that already-established behavior.
  end
end
