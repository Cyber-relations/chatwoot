# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/draft_result'

class Toybaco::GrowthDraftSweepJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    pending = Toybaco::GrowthDraftRequest.where(state: %w[queued running])
    pending.where('expires_at <= ?', Time.now.utc).find_each { |request| Toybaco::Growth::DraftResult.new(request).fail!('expired') }
    pending.where(state: 'queued').where('expires_at > ?', Time.now.utc).find_each { |request| Toybaco::GrowthDraftJob.perform_later(request.id) }
  end
end
