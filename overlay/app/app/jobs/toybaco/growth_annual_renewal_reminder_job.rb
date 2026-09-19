# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/annual_renewal_reminder'

class Toybaco::GrowthAnnualRenewalReminderJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    return unless Toybaco::Growth::RenewalReminder.enabled?

    Account.where("internal_attributes ->> 'toybaco_cycle' = ?", 'year').find_each(batch_size: 100) do |account|
      Toybaco::Growth::AnnualRenewalReminder.new(account).perform
    end
  end
end
