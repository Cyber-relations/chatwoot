# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/draft_work'

class Toybaco::GrowthDraftJob < ApplicationJob
  queue_as :default

  def perform(request_id)
    request = Toybaco::GrowthDraftRequest.find_by(id: request_id)
    Toybaco::Growth::DraftWork.new(request).perform if request
  end
end
