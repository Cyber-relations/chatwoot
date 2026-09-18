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
  end

  private

  def due
    exhausted = Toybaco::GrowthAiGrant.where(source: 'trial', revoked_at: nil).where('used >= units').select(:account_id)
    active = Toybaco::GrowthTrial.where(completed_at: nil)
    active.where('ends_at <= ?', Time.now.utc).or(active.where(account_id: exhausted))
  end
end
