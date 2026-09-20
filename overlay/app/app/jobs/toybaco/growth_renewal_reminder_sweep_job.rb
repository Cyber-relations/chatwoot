# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/renewal_reminder'

class Toybaco::GrowthRenewalReminderSweepJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    return unless Toybaco::Growth::RenewalReminder.enabled?

    Account.where("internal_attributes -> 'toybaco_growth_renewal_failure' IS NOT NULL").find_each(batch_size: 100) do |account|
      Toybaco::Growth::RenewalReminder.new(account).perform
    end
  end
end
