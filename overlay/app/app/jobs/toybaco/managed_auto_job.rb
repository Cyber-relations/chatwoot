# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/managed_auto_work'

class Toybaco::ManagedAutoJob < ApplicationJob
  queue_as :default

  def perform(request_id)
    request = Toybaco::GrowthAutoRequest.find_by(id: request_id)
    Toybaco::Growth::ManagedAutoWork.new(request).perform if request
  end
end
