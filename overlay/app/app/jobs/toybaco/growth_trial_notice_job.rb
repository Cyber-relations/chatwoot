# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/trial_notice_delivery'

class Toybaco::GrowthTrialNoticeJob < ApplicationJob
  queue_as :mailers

  def perform(id)
    notice = Toybaco::GrowthTrialNotice.find_by(id: id)
    Toybaco::Growth::TrialNoticeDelivery.new(notice).perform if notice
  end
end
