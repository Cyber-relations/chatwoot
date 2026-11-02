# frozen_string_literal: true

require_relative 'managed_auto'

# Closes automatic requests whose model result stayed unknown (started or uncertain). Bedrock answers
# only on the request's own HTTP response (read timeout 40, model deadline 55) and the AI lease is 300
# seconds, so a worker that has not finished by CLOSE_AFTER seconds from its start has lost its result.
# ManagedAutoWork#finish! saves a reply only while the request is still started, under the same Account
# fence, so a late worker finds the row closed and answers nothing. The row keeps its start and operation
# and its reason names the state it was in; the reservation ends without a charge, and a lost start goes
# to staff as an uncertain one already did. Rows of a missing store stay as minimal unresolved history.
module Toybaco::Growth::ManagedAutoUnknown
  AUTO = Toybaco::Growth::ManagedAuto
  CLOSE_AFTER = 900

  module_function

  # Returns [closed, deferred]. A store busy under its Account fence is left to the next run.
  def sweep!(now: Time.now.utc)
    closed = deferred = 0
    AUTO::REQUESTS.unresolved.where('started_at <= ?', now - CLOSE_AFTER).find_each do |request|
      closed += 1 if close!(request, now: now)
    rescue Toybaco::Growth::InboxRetention::Busy
      deferred += 1
    rescue ActiveRecord::RecordNotFound
      next
    end
    [closed, deferred]
  end

  def close!(request, now: Time.now.utc)
    AUTO.locked(request.account_id) do
      request.reload
      operation = Toybaco::GrowthAiOperation.find_by(id: request.operation_id, account_id: request.account_id)
      next unless due?(request, operation, now)

      operation.update!(state: 'expired') if operation&.state == 'reserved'
      settle!(request, now)
    end
  end

  def due?(request, operation, now)
    AUTO::REQUESTS::UNRESOLVED.include?(request.state) && request.started_at <= now - CLOSE_AFTER &&
      !(operation&.state == 'reserved' && operation.lease_expires_at > now)
  end

  def settle!(request, now)
    previous = request.state
    request.update!(state: 'cancelled', terminal_at: now, reason: "#{previous}_expired")
    AUTO.open_conversation!(request) if previous == 'started'
    installation = AUTO::INSTALLATIONS.find_by(id: request.installation_id, account_id: request.account_id)
    AUTO.finish_stop!(installation) if installation
    previous
  end
end
