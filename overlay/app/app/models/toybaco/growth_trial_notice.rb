# frozen_string_literal: true

class Toybaco::GrowthTrialNotice < ApplicationRecord
  self.table_name = 'toybaco_growth_trial_notices'
  belongs_to :account
  belongs_to :trial, class_name: 'Toybaco::GrowthTrial'
  belongs_to :user
  validates :kind, inclusion: { in: %w[deadline remaining] }
  validates :state, inclusion: { in: %w[queued dispatching attempted uncertain cancelled] }
  after_create_commit :enqueue_delivery

  private

  def enqueue_delivery
    Toybaco::GrowthTrialNoticeJob.perform_later(id) if Toybaco::Growth::TrialNoticeDelivery.enabled?
  end
end
