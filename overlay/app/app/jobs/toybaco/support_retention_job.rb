# frozen_string_literal: true

require_relative '../../../lib/toybaco/support/reports'

class Toybaco::SupportRetentionJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    # Retention continues even when customer-facing support is disabled.
    Toybaco::Support::Reports.expire!
  end
end
