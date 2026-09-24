# frozen_string_literal: true

require_relative '../subscription_sync'
require_relative 'inbox_upgrade_record'

module Toybaco::Growth::PostingPaidUpgradeTerms
  Record = Toybaco::Growth::PostingPreparationRecord
  Upgrade = Toybaco::Growth::InboxUpgradeRecord

  module_function

  def target(subscription, source, account, now:)
    binding = source.fetch('binding')
    before = binding.fetch('contract')
    after = Toybaco::SubscriptionSync.new(client: nil).resolve(subscription, previous: before)
    coverage = Toybaco::Growth::PaidCoverage.new(subscription, after).verified
    fresh = binding.merge('contract' => after, 'coverage' => coverage)
    validate_provider!(subscription, binding)
    validate_change!(binding, fresh, account, now)
    fresh
  end

  def validate_change!(binding, fresh, account, now)
    before = binding['contract']
    after = fresh['contract']
    raise Record::Invalid unless Upgrade.upgrade?(before, after) && before['addons'] == after['addons'] &&
                                 Upgrade.periods_follow?(binding['coverage'], fresh['coverage'], binding, fresh, now.to_i)
    raise Record::Invalid unless limits(after).zip(limits(before)).all? { |new_value, old_value| new_value >= old_value }

    validate_active!(account, before, after)
  end

  def validate_active!(account, before, after)
    raise Record::Invalid unless account.active? && before['legacy'] == false && after['legacy'] == false
  end

  def validate_provider!(subscription, binding)
    expected = [binding['subscription_id'], binding['customer_id'], binding['mode'] == 'live', 'active']
    raise Record::Invalid unless subscription.values_at('id', 'customer', 'livemode', 'status') == expected
    raise Record::Invalid unless subscription.values_at('pending_update', 'pause_collection', 'cancel_at').all?(&:nil?) &&
                                 subscription['cancel_at_period_end'] != true &&
                                 subscription.dig('metadata', 'toybaco_purchase_nonce') == binding['purchase_nonce']

    validate_invoice!(subscription['latest_invoice'], binding)
  end

  def validate_invoice!(invoice, binding)
    raise Record::Invalid unless invoice.is_a?(Hash) && invoice.values_at('billing_reason', 'status', 'currency', 'amount_remaining') ==
                                                        ['subscription_update', 'paid', 'jpy', 0]
    raise Record::Invalid unless invoice['amount_due'].is_a?(Integer) && invoice['amount_due'].positive? &&
                                 invoice['amount_paid'] == invoice['amount_due']
    raise Record::Invalid unless invoice.values_at('customer', 'livemode') == [binding['customer_id'], binding['mode'] == 'live']
  end

  def limits(contract)
    values = contract.fetch('entitlements').fetch('limits').values_at('posting_accounts', 'scheduled_posts_per_account')
    raise Record::Invalid unless values.all? { |value| value.is_a?(Integer) && value.between?(1, 10_000) }

    values
  end

  def rank(contract)
    value = Upgrade::RANKS.index(contract['plan_id'])
    raise Record::Invalid unless value

    value + 1
  end
end
