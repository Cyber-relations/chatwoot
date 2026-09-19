# frozen_string_literal: true

require_relative '../../../lib/toybaco/connections/handoff/access'

class Toybaco::ConnectionHandoffSweepJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    records = Toybaco::ConnectionHandoff.all
    expired = records.where('expires_at <= ?', Time.now.utc)
    expired.where('encrypted_recipient IS NOT NULL OR claim_digest IS NOT NULL OR encrypted_verification IS NOT NULL').limit(100).each do |record|
      record.with_lock { record.update!(Toybaco::Connections::Handoff::Access::PRIVATE_FIELDS) if record.expires_at <= Time.now.utc }
    end
    return unless Toybaco::Connections::Handoff::Access.enabled?

    records.where(state: 'issued', delivery_state: 'queued').where('expires_at > ?', Time.now.utc).limit(100).each do |record|
      Toybaco::ConnectionHandoffMailJob.perform_later(record.id, record.verification_revision)
    end
  end
end
