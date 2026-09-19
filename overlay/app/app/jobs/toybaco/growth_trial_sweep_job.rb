# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/trial_lifecycle'

class Toybaco::GrowthTrialSweepJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    due.find_each do |trial|
      account = Account.find_by(id: trial.account_id)
      if account
        Toybaco::Growth::TrialLifecycle.new(account).refresh!
      else
        trial.update!(completed_at: Time.now.utc, completion_reason: 'store_deleted')
      end
    end
    retry_queued_notices
  end

  private

  def due
    exhausted = Toybaco::GrowthAiGrant.where(source: 'trial', revoked_at: nil).where('used >= units - 20').select(:account_id)
    active = Toybaco::GrowthTrial.where(completed_at: nil)
    active.where('ends_at <= ?', Time.now.utc + 3.days).or(active.where(account_id: exhausted))
  end

  def retry_queued_notices
    return unless Toybaco::Growth::TrialNoticeDelivery.enabled?

    Toybaco::GrowthTrialNotice.where(state: 'queued').find_each { |notice| Toybaco::GrowthTrialNoticeJob.perform_later(notice.id) }
  end
end
