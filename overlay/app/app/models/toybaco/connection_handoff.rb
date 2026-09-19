# frozen_string_literal: true

class Toybaco::ConnectionHandoff < ApplicationRecord
  self.table_name = 'toybaco_connection_handoffs'
  belongs_to :account
  validates :creator_id, :public_id, :request_id, :request_digest, :provider, :target_key, :recipient_digest, :expires_at, presence: true
  validates :state, inclusion: { in: %w[issued claimed completed revoked] }
end
