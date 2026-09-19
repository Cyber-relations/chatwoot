# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/payment_execution'

class Toybaco::GrowthPaymentJob < ApplicationJob
  queue_as :default

  def perform(event_id)
    event = Toybaco::GrowthPaymentEvent.find_by(id: event_id)
    Toybaco::Growth::PaymentExecution.new(event).call if event
  end
end
