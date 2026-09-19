# frozen_string_literal: true

class Toybaco::GrowthPackOrder < ApplicationRecord
  self.table_name = 'toybaco_growth_pack_orders'

  validates :account_id, :owner_id, :payload, presence: true
  validates :state, inclusion: { in: %w[prepared open payment_pending complete expired refunded payment_review] }
  validates :nonce, format: { with: /\A[0-9a-f]{48}\z/ }
  validates :request_key, format: { with: /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/ }
end
