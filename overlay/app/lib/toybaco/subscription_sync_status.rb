# frozen_string_literal: true

require_relative 'entitlements'

# Status part of SubscriptionSync: subscription status, cancel flag and billing access
# from the fresh subscription.
module Toybaco::SubscriptionSyncStatus
  private

  # While a renewal period waits for its dispatch phase, only the fresh subscription
  # status and a cleared cancel flag are written: status-only repairs, it never closes
  # a fence (a new cancel reservation waits for the full Sync). Contract, coverage, AI
  # units, access (suspend / resume, posting) and child stores are left to that Sync.
  def apply_status_only(account, subscription)
    attrs = Toybaco::Entitlements.attributes(account)
    fields = status_fields(subscription)
    fields.delete('toybaco_cancel_at_period_end') if fields['toybaco_cancel_at_period_end']
    account.update!(internal_attributes: attrs.merge(fields))
    'renewal_pending'
  end

  def apply_status(account, subscription, contract, outcome)
    attrs = Toybaco::Entitlements.attributes(account)
    policy = contract && contract['billing_policy']
    policy = {} unless policy.is_a?(Hash)
    updates = status_fields(subscription).merge('toybaco_billing_review' => outcome == 'needs_review',
                                                'toybaco_billing_payment_pending' => outcome == 'payment_pending')
    state = access_state(account, attrs, updates, policy)
    account.update!(state.merge(internal_attributes: attrs.merge(updates)))
  end

  def status_fields(subscription)
    { 'toybaco_subscription_status' => subscription.fetch('status'),
      'toybaco_cancel_at_period_end' => subscription['cancel_at_period_end'] == true }
  end

  def access_state(account, attrs, updates, policy)
    status = updates['toybaco_subscription_status']
    state = {}
    if suspended_status?(policy, status)
      if account.active?
        updates['toybaco_billing_suspended'] = true
        state[:status] = 'suspended'
      end
      updates['postiz'] = (attrs['postiz'] || {}).merge('enabled' => false)
    elsif resume_billing?(policy, status, attrs, updates)
      updates['toybaco_billing_suspended'] = false
      state[:status] = 'active' if account.status.to_s == 'suspended'
    end
    state
  end

  def suspended_status?(policy, status)
    Array(policy['suspended_statuses']).include?(status) || status == 'canceled'
  end

  def resume_billing?(policy, status, attrs, updates)
    Array(policy['grace_statuses']).include?(status) && !updates['toybaco_billing_review'] &&
      !updates['toybaco_billing_payment_pending'] && attrs['toybaco_billing_suspended'] == true
  end
end
