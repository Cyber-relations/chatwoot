# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/renewal_dispatch_execution'

class Toybaco::GrowthRenewalDispatchJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform(id)
    row = Toybaco::GrowthRenewalDispatch.find_by(id: id)
    Toybaco::Growth::RenewalDispatchExecution.new(row).call if row
  end
end
