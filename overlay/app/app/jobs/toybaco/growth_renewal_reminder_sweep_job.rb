# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/renewal_reminder'
require_relative '../../../lib/toybaco/growth/renewal_free_notice'

class Toybaco::GrowthRenewalReminderSweepJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    return unless Toybaco::Growth::RenewalReminder.enabled?

    Account.where("internal_attributes -> 'toybaco_growth_renewal_failure' IS NOT NULL").find_each(batch_size: 100) do |account|
      Toybaco::Growth::RenewalReminder.new(account).perform
    end
    recover_free_notices
  end

  private

  # The dispatch enqueues the Free transition notice once after the Free write, and a queue failure is only logged.
  # This sends a notice that was never enqueued or never ran, for a Free return of the last 7 days. RenewalFreeNotice
  # claims it under the lock, so a notice already recorded is never sent again. The notices flag is the one read
  # above, at the sweep. A store that fails (perform raises a failure before its claim) does not stop the others.
  def recover_free_notices
    now = Time.now.utc
    Toybaco::Growth::RenewalFreeNotice.candidates.find_each(batch_size: 100) do |account|
      next unless Toybaco::Growth::RenewalFreeNotice.pending?(account, now: now)

      Toybaco::Growth::RenewalFreeNotice.new(account).perform
    rescue StandardError => e
      Rails.logger.warn("toybaco_renewal_free_notice_sweep_failed account=#{account.id} class=#{e.class.name}")
    end
  end
end
