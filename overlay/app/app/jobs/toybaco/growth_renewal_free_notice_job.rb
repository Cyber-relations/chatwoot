# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/renewal_free_notice'

# Enqueued by the renewal dispatch after its Free write committed. RenewalFreeNotice sends at most once per transition.
class Toybaco::GrowthRenewalFreeNoticeJob < ApplicationJob
  queue_as :mailers

  def perform(account_id)
    account = Account.find_by(id: account_id)
    Toybaco::Growth::RenewalFreeNotice.new(account).perform if account
  end
end
