# frozen_string_literal: true

class Toybaco::GrowthAiOperation < ApplicationRecord
  self.table_name = 'toybaco_growth_ai_operations'

  belongs_to :account
  belongs_to :grant, class_name: 'Toybaco::GrowthAiGrant', inverse_of: :operations

  validates :request_key, format: { with: /\A[0-9a-f-]{16,80}\z/ }
  validates :context_digest, :token_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :kind, inclusion: { in: %w[reply_draft post_draft automatic_reply] }
  validates :state, inclusion: { in: %w[reserved consumed released expired] }
  validates :lease_expires_at, presence: true
  validates :result_reference, length: { maximum: 160 }, allow_nil: true
end
