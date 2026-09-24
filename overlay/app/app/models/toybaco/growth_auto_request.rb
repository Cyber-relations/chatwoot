# frozen_string_literal: true

class Toybaco::GrowthAutoRequest < ApplicationRecord
  self.table_name = 'toybaco_growth_auto_requests'
  UNRESOLVED = %w[started uncertain].freeze
  validates :account_id, :inbox_id, :installation_id, :generation, :epoch, :message_id, :conversation_id, :enqueue_after, presence: true
  validates :state, inclusion: { in: %w[queued started uncertain completed handoff cancelled] }
  scope :unresolved, -> { where(state: UNRESOLVED) }
end
