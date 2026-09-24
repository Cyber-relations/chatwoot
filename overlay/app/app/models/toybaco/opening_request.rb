# frozen_string_literal: true

class Toybaco::OpeningRequest < ApplicationRecord
  self.table_name = 'toybaco_opening_requests'
  attr_readonly :mode, :session_id
  before_update :preserve_account_binding!
  validates :mode, inclusion: { in: %w[test live] }
  validates :session_id, format: { with: /\Acs_(?:test_|live_)?[A-Za-z0-9]{1,200}\z/ }
  validates :state, inclusion: { in: %w[pending account_ready attention] }

  private

  def preserve_account_binding!
    return unless state_in_database == 'account_ready'

    keys = %w[state subscription_id contract_digest account_id owner_id account_ready_at industry]
    raise ActiveRecord::ReadOnlyRecord if keys.any? { |key| will_save_change_to_attribute?(key) }
  end
end
