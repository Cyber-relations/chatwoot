# frozen_string_literal: true

class Toybaco::OpeningNotice < ApplicationRecord
  self.table_name = 'toybaco_opening_notices'
  belongs_to :opening_request, class_name: 'Toybaco::OpeningRequest'
  attr_readonly :opening_request_id, :request_id, :actor_id, :created_at, :retain_until
  before_update :preserve_attempt!
  validates :request_id, format: { with: /\A(?:initial|[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})\z/ }
  validates :state, inclusion: { in: %w[queued dispatching attempted uncertain cancelled] }

  private

  def preserve_attempt!
    transitions = { 'queued' => %w[dispatching cancelled], 'dispatching' => %w[attempted uncertain cancelled] }
    raise ActiveRecord::ReadOnlyRecord unless transitions.fetch(state_in_database, []).include?(state)
  end
end
