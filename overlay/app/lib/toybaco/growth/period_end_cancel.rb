# frozen_string_literal: true

require_relative '../growth_terms'

module Toybaco::Growth
end

# A paid growth subscription that Stripe ended at its period end after the owner's
# own cancellation. Pure rules: the Sync applies them to the attributes it is about
# to save, the Free return re-checks them after a fresh provider read.
module Toybaco::Growth::PeriodEndCancel
  FLAGS = %w[TOYBACO_GROWTH_FREE_RETURN_ENABLED TOYBACO_POSTING_RETENTION_ENABLED TOYBACO_INBOX_RETENTION_ENABLED].freeze
  FAILURE_KEY = 'toybaco_growth_renewal_failure'
  STORE_PURCHASE_KEY = 'toybaco_store_purchase'
  JOURNAL_KEY = 'toybaco_growth_renewal_transition'
  SETTLED_INVOICES = %w[paid void].freeze
  REASON = 'cancellation_requested'
  TIMES = %w[canceled_at cancel_at ended_at].freeze

  module_function

  # Only for a caller that opted in because it runs the Free return after the Sync, and
  # only while all three rollout flags are open. Any other caller or a half-open rollout
  # keeps the existing suspension instead of leaving a paid store active without a return.
  def eligible?(account, attrs, subscription, environment:, free_return:)
    free_return == true && FLAGS.all? { |flag| environment[flag] == 'true' } && account?(account, attrs) && subscription?(subscription)
  end

  # An active paid growth store whose saved status is the ended period-end
  # cancellation, without a renewal failure, billing hold or another journal.
  def account?(account, attrs)
    account.active? && paid_contract?(attrs['toybaco_contract']) && unblocked?(attrs) && ended_status?(attrs) && journal?(attrs)
  end

  def paid_contract?(contract)
    contract.is_a?(Hash) && contract['plan_id'] != 'free' && contract['legacy'] != true && contract['addons'] == [] &&
      contract.dig('entitlements', 'ai_meter') == Toybaco::GrowthTerms::METER
  end

  def unblocked?(attrs)
    !attrs.key?(FAILURE_KEY) && !attrs.key?(STORE_PURCHASE_KEY) && !attrs['toybaco_billing_review'] &&
      !attrs['toybaco_billing_payment_pending']
  end

  def ended_status?(attrs)
    attrs['toybaco_subscription_status'] == 'canceled' && attrs['toybaco_cancel_at_period_end'] == true
  end

  # No journal, or the unfinished journal of this cancellation. A renewal failure
  # journal and the completed return of an earlier subscription keep the existing
  # suspension: the hold receipts of one store take a single return.
  def journal?(attrs)
    return true unless attrs.key?(JOURNAL_KEY)

    value = attrs[JOURNAL_KEY]
    value.is_a?(Hash) && value['binding'].is_a?(Hash) && value['binding'].key?('cancel') && value['state'] != 'free_completed'
  end

  # cancel_at_period_end stays true after the end. A reason is absent in some API
  # versions; when present it must be the owner's request, never a payment failure.
  def subscription?(subscription)
    subscription.is_a?(Hash) && subscription['status'] == 'canceled' && subscription['cancel_at_period_end'] == true &&
      evidence?(evidence(subscription)) && requested?(subscription['cancellation_details']) &&
      settled?(subscription['latest_invoice'])
  end

  def evidence(subscription)
    details = subscription['cancellation_details']
    { 'canceled_at' => subscription['canceled_at'], 'cancel_at' => subscription['cancel_at'],
      'ended_at' => subscription['ended_at'], 'reason' => details.is_a?(Hash) ? details['reason'] : nil }
  end

  def evidence?(value)
    value.is_a?(Hash) && value.keys.sort == (TIMES + ['reason']).sort && TIMES.all? { |key| value[key].is_a?(Integer) } &&
      (value['reason'].nil? || value['reason'].is_a?(String))
  end

  def requested?(details)
    details.nil? || (details.is_a?(Hash) && [nil, REASON].include?(details['reason']))
  end

  # The latest invoice is expanded by the client; an unexpanded or unpaid one fails closed.
  def settled?(invoice)
    invoice.nil? || (invoice.is_a?(Hash) && SETTLED_INVOICES.include?(invoice['status']))
  end
end
