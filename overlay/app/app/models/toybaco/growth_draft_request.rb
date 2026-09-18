# frozen_string_literal: true

class Toybaco::GrowthDraftRequest < ApplicationRecord
  self.table_name = 'toybaco_growth_draft_requests'

  belongs_to :account
  belongs_to :operation, class_name: 'Toybaco::GrowthAiOperation'
  validates :user_id, :conversation_id, :incoming_id, :operation_id, :draft_digest, :expires_at, presence: true
  validates :state, inclusion: { in: %w[queued running completed failed] }
end
