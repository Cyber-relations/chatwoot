# frozen_string_literal: true

class Toybaco::SupportReport < ApplicationRecord
  self.table_name = 'toybaco_support_reports'
  belongs_to :account
  belongs_to :user
  attr_readonly :account_id, :user_id, :request_id, :category, :article_id, :knowledge_version, :expires_at, :diagnostics_expires_at

  validates :request_id, format: { with: /\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/ }
  validates :category, inclusion: { in: %w[product billing identity security] }
  validates :state, inclusion: { in: %w[received reviewing resolved] }
  validates :assignee_id, numericality: { only_integer: true, greater_than: 0 }
end
