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
  SUBSCRIPTION = /\Asub_[A-Za-z0-9]+\z/
  UNFINISHED = %w[prepared provider_closed].freeze
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
    store?(account, attrs) && paid_contract?(attrs['toybaco_contract']) && unblocked?(attrs) && ended_status?(attrs) && journal?(attrs)
  end

  # Active, or billing-suspended after this return ended in attention: it already closed
  # this subscription under a provider_closed cancel journal, so a re-armed return may
  # continue and lifts the suspension when it completes. No other suspension resumes.
  def store?(account, attrs)
    account.active? || (account.status.to_s == 'suspended' && attrs['toybaco_billing_suspended'] == true && closed_journal?(attrs))
  end

  def closed_journal?(attrs)
    unfinished_journal?(attrs) && attrs[JOURNAL_KEY]['state'] == 'provider_closed'
  end

  # Only the current growth terms: the retention snapshot and the Free return are defined for them,
  # so an earlier growth version keeps the existing suspension instead of a return that cannot finish.
  def paid_contract?(contract)
    contract.is_a?(Hash) && contract['plan_id'] != 'free' && contract['plan_version'] == Toybaco::GrowthTerms::VERSION &&
      contract['legacy'] != true && contract['addons'] == [] && contract.dig('entitlements', 'ai_meter') == Toybaco::GrowthTerms::METER
  end

  def unblocked?(attrs)
    !attrs.key?(FAILURE_KEY) && !attrs.key?(STORE_PURCHASE_KEY) && !attrs['toybaco_billing_review'] &&
      !attrs['toybaco_billing_payment_pending']
  end

  def ended_status?(attrs)
    attrs['toybaco_subscription_status'] == 'canceled' && attrs['toybaco_cancel_at_period_end'] == true
  end

  # No journal, the unfinished cancel journal of this subscription, or the completed
  # return of an earlier subscription: a store that bought again after a Free return
  # returns anew, and its holds replace the returned generation. A renewal failure
  # journal, a recovered payment, another subscription's unfinished journal and this
  # subscription's own completed return keep the existing suspension.
  def journal?(attrs)
    return true unless attrs.key?(JOURNAL_KEY)

    value = attrs[JOURNAL_KEY]
    return false unless value.is_a?(Hash) && value['binding'].is_a?(Hash)

    return earlier_subscription?(value['binding']['subscription_id'], attrs['toybaco_subscription_id']) if value['state'] == 'free_completed'

    unfinished_journal?(attrs)
  end

  # This subscription's unfinished cancel journal: its return started and is not complete.
  # Both subscription ids must be present Stripe ids (never nil == nil) and the cancel
  # binding must hold Stripe's closure evidence.
  def unfinished_journal?(attrs)
    value = attrs[JOURNAL_KEY]
    value.is_a?(Hash) && value['binding'].is_a?(Hash) && evidence?(value['binding']['cancel']) && UNFINISHED.include?(value['state']) &&
      same_subscription?(value['binding']['subscription_id'], attrs['toybaco_subscription_id'])
  end

  # The latch of SubscriptionReconciliation.suspension_due?: the store still holds the
  # request's subscription under a cancel journal of it that is not complete. Looser than
  # unfinished_journal? on purpose (the cancel evidence is not checked): a malformed
  # binding still falls back to the suspension, while it never resumes from one.
  def return_latched?(attrs, subscription_id)
    value = attrs[JOURNAL_KEY]
    same_subscription?(subscription_id, attrs['toybaco_subscription_id']) && value.is_a?(Hash) && value['binding'].is_a?(Hash) &&
      value['binding'].key?('cancel') && UNFINISHED.include?(value['state']) && value['binding']['subscription_id'] == subscription_id
  end

  # The mark a Sync leaves when it skips the suspension for the Free return, journal or not:
  # this subscription's ended period-end cancellation saved on a paid growth contract (the
  # attributes account? reads). With the request in attention the store falls back to the
  # suspension (SubscriptionReconciliation.suspension_due?); without a journal of this
  # subscription it never resumes from there.
  def suspension_skipped?(attrs, subscription_id)
    same_subscription?(subscription_id, attrs['toybaco_subscription_id']) && paid_contract?(attrs['toybaco_contract']) && ended_status?(attrs)
  end

  def same_subscription?(bound, current)
    bound.is_a?(String) && bound.match?(SUBSCRIPTION) && bound == current
  end

  def earlier_subscription?(bound, current)
    [bound, current].all? { |id| id.is_a?(String) && id.match?(SUBSCRIPTION) } && bound != current
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
