# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/post_draft_work'

class Toybaco::GrowthPostDraftJob < ApplicationJob
  queue_as :default

  def perform(request_id)
    request = Toybaco::GrowthPostDraft.find_by(id: request_id)
    Toybaco::Growth::PostDraftWork.new(request).perform if request
  end
end
