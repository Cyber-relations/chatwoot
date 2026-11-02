# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/managed_auto_ingress'
require_relative '../../../lib/toybaco/growth/managed_auto_unknown'

class Toybaco::ManagedAutoSweepJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    Toybaco::GrowthAutoRequest.where(state: 'queued').where('enqueue_after <= ?', Time.now.utc).find_each do |request|
      Toybaco::Growth::ManagedAutoIngress.enqueue(request)
    end
    # Before stopping installations, so a stop that waits only for these closes in the same run.
    closed, deferred = Toybaco::Growth::ManagedAutoUnknown.sweep!
    Rails.logger.warn("TOYBACO_MANAGED_AUTO_UNKNOWN_CLOSED closed=#{closed} deferred=#{deferred}") if (closed + deferred).positive?
    Toybaco::GrowthAutoInstallation.where(state: 'stopping').find_each do |installation|
      Toybaco::Growth::ManagedAuto.locked(installation.account_id) do
        Toybaco::Growth::ManagedAuto.finish_stop!(installation.reload)
      end
    rescue ActiveRecord::RecordNotFound
      # Keep the minimal unresolved history; a missing account is not completion.
      next
    end
  end
end
