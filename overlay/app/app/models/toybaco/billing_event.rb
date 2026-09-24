# frozen_string_literal: true

class Toybaco::BillingEvent < ApplicationRecord
  self.table_name = 'toybaco_billing_events'
  attr_readonly :event_id, :mode, :action, :reference_id, :snapshot, :payload_digest

  validates :event_id, :mode, :action, :reference_id, :snapshot, :payload_digest, :state, :next_attempt_at, :deadline_at, presence: true
  validates :event_id, format: { with: /\Aevt_[A-Za-z0-9]{1,200}\z/ }
  validates :mode, inclusion: { in: %w[test live] }
  validates :action, inclusion: { in: %w[growth_checkout subscription_notice opening_checkout] }
  validates :state, inclusion: { in: %w[pending queued processing completed attention] }
  validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :attempt_limit, numericality: { only_integer: true, greater_than: 0 }
end
