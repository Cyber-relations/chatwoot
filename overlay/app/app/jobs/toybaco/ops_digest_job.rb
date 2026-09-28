# frozen_string_literal: true

require_relative '../../../lib/toybaco/ops/digest'

class Toybaco::OpsDigestJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    Toybaco::Ops::Digest.new.run!
  end
end
