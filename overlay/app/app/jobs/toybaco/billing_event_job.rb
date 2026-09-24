# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/billing_execution'

class Toybaco::BillingEventJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform(id)
    event = Toybaco::BillingEvent.find_by(id: id)
    Toybaco::Growth::BillingExecution.new(event).call if event
  end
end
