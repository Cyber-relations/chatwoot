# frozen_string_literal: true

class Toybaco::GrowthPaymentEvent < ApplicationRecord
  self.table_name = 'toybaco_growth_payment_events'
  attr_readonly :event_id, :action, :reference_id, :snapshot, :payload_digest

  validates :event_id, :action, :reference_id, :snapshot, :payload_digest, :state, :next_attempt_at, presence: true
  validates :event_id, format: { with: /\Aevt_[A-Za-z0-9]+\z/ }
  validates :action, inclusion: { in: %w[pack_checkout pack_refund renewal_failure] }
  validates :state, inclusion: { in: %w[pending queued processing completed attention] }
  validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :attempt_limit, numericality: { only_integer: true, greater_than: 0 }
end
