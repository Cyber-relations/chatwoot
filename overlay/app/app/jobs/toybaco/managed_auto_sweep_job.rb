# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/managed_auto_ingress'

class Toybaco::ManagedAutoSweepJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    Toybaco::GrowthAutoRequest.where(state: 'queued').where('enqueue_after <= ?', Time.now.utc).find_each do |request|
      Toybaco::Growth::ManagedAutoIngress.enqueue(request)
    end
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
