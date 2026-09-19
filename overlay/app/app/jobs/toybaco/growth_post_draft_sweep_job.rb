# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/post_draft_result'

class Toybaco::GrowthPostDraftSweepJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    pending = Toybaco::GrowthPostDraft.where(state: %w[queued running])
    pending.where('expires_at <= ?', Time.now.utc).find_each { |request| Toybaco::Growth::PostDraftResult.new(request).fail!('expired') }
    pending.where(state: 'queued').where('expires_at > ?', Time.now.utc).find_each { |request| Toybaco::GrowthPostDraftJob.perform_later(request.id) }
    Toybaco::GrowthPostDraft.where(state: 'completed').where('result_expires_at <= ?', Time.now.utc)
                            .where.not(encrypted_result: nil).find_each { |request| request.update!(encrypted_result: nil) }
  end
end
