# frozen_string_literal: true

require_relative '../../../lib/toybaco/connections/handoff/delivery'

class Toybaco::ConnectionHandoffMailJob < ApplicationJob
  queue_as :mailers

  def perform(id, revision)
    record = Toybaco::ConnectionHandoff.find_by(id: id)
    Toybaco::Connections::Handoff::Delivery.new(record, revision).perform if record
  end
end
