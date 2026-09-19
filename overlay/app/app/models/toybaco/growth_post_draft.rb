# frozen_string_literal: true

class Toybaco::GrowthPostDraft < ApplicationRecord
  self.table_name = 'toybaco_growth_post_drafts'
  belongs_to :account
  belongs_to :operation, class_name: 'Toybaco::GrowthAiOperation'
  validates :user_id, :organization_id, :editor_id, :draft_digest, :facts_revision, :expires_at, presence: true
  validates :state, inclusion: { in: %w[queued running completed failed] }
end
