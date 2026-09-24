# frozen_string_literal: true

class Toybaco::SubscriptionSyncRequest < ApplicationRecord
  self.table_name = 'toybaco_subscription_sync_requests'
  attr_readonly :subscription_id, :mode

  validates :subscription_id, format: { with: /\Asub_[A-Za-z0-9]{1,200}\z/ }
  validates :mode, inclusion: { in: %w[test live] }
  validates :state, inclusion: { in: %w[pending running completed superseded attention] }
  validates :requested_revision, numericality: { only_integer: true, greater_than: 0 }
  validates :completed_revision, :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :deadline_at, :next_attempt_at, :next_enqueue_at, presence: true
end
