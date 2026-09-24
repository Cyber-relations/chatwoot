# frozen_string_literal: true

# Once handoff can have committed remotely, neither timeout nor flag-off may
# release the writer/admission fence. Only exact confirmation resolves it.
module Toybaco::Growth::PostingRenewalFence
  module_function

  def guard!(account_id, except_request_id: nil)
    return unless defined?(Toybaco::GrowthPostingRenewal)

    row = Toybaco::GrowthPostingRenewal.where(account_id: account_id, state: %w[transferring applied]).first
    return unless row

    require_relative 'posting_renewal_record'
    Toybaco::Growth::PostingRenewalRecord.validate!(row, now: Time.now.utc)
    return if except_request_id && row.request_id == except_request_id

    raise Toybaco::Growth::PostingExecutionContext::Busy
  end
end
