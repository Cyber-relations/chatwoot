# frozen_string_literal: true

require_relative 'scheduled_downgrade_record'
require_relative 'inbox_upgrade_record'

module Toybaco::Growth::ScheduledGrantUpgradeRecord
  Record = Toybaco::Growth::PostingPreparationRecord
  Origin = Toybaco::Growth::ScheduledDowngradeRecord
  Upgrade = Toybaco::Growth::InboxUpgradeRecord
  Invalid = Record::Invalid
  FIELDS = %w[version account_id scheduled_downgrade_id grant_id parent_hash source_binding target_binding period
              grants_hash additional_units base_units created_at subscription_hash invoice_hash].freeze

  module_function

  def chain(origin, now: Time.now.utc)
    Origin.validate!(origin, now: now)
    raise Invalid unless origin.recovery && origin.grant_id

    rows = Toybaco::GrowthScheduledGrantUpgrade.where(scheduled_downgrade_id: origin.id).order(:id).limit(3).to_a
    raise Invalid if rows.length > 2

    source = origin.recovery['binding'].merge('coverage' => origin.recovery['coverage'])
    parent = origin.recovery_hash
    rows.each do |row|
      validate!(row, origin, source, parent, now)
      source = row.receipt['target_binding']
      parent = row.receipt_hash
    end
    rows
  end

  def validate!(row, origin, source, parent, now)
    value = row.receipt
    Origin.hash_keys!(value, FIELDS)
    raise Invalid unless value.values_at('version', 'account_id', 'scheduled_downgrade_id', 'grant_id', 'parent_hash') ==
                         [1, origin.account_id, origin.id, origin.grant_id, parent]
    raise Invalid unless row.attributes.values_at('account_id', 'scheduled_downgrade_id', 'grant_id', 'parent_hash') ==
                         [origin.account_id, origin.id, origin.grant_id, parent]
    raise Invalid unless row.receipt_hash == Record.digest(value) && row.operation_id == operation_id(value)

    bindings!(value, origin, source)
    amounts!(value, row, now)
  end

  def bindings!(value, origin, source)
    target = value['target_binding']
    raise Invalid unless value['source_binding'] == source && value['period'] == Origin.period(origin.receipt)

    Origin.hash_keys!(target, %w[contract coverage customer_id mode purchase_nonce subscription_id])
    raise Invalid unless source.slice('subscription_id', 'customer_id', 'mode', 'purchase_nonce') ==
                         target.slice('subscription_id', 'customer_id', 'mode', 'purchase_nonce')
    raise Invalid unless Upgrade.upgrade?(source['contract'], target['contract']) &&
                         Upgrade.periods_follow?(source['coverage'], target['coverage'], source, target, value['created_at'])
  end

  def amounts!(value, row, now)
    raise Invalid unless %w[grants_hash subscription_hash invoice_hash].all? { |key| Record.hash?(value[key]) }

    nonnegative!(value)

    timestamps!(value, row, now)
    raise Invalid unless value['additional_units'] <= value.dig('target_binding', 'coverage', 'normal_limit') && value['base_units'].positive?
  end

  def nonnegative!(value)
    raise Invalid unless %w[additional_units base_units created_at].all? { |key| value[key].is_a?(Integer) && value[key] >= 0 }
  end

  def timestamps!(value, row, now)
    raise Invalid unless value['created_at'] == row.created_at.to_i && row.created_at == row.updated_at && row.created_at <= now
  end

  def operation_id(value)
    Record.digest(['scheduled_grant_upgrade', value['account_id'], value['scheduled_downgrade_id'], value['parent_hash'],
                   value.dig('target_binding', 'coverage', 'invoice_id')])
  end

  def current!(account, binding)
    identity!(account, binding)
    attrs = Toybaco::Entitlements.attributes(account)
    raise Invalid unless attrs[Toybaco::Growth::PaidPeriod::KEY]&.except('current_period_start', 'current_base_limit') == binding['coverage']
  end

  def identity!(account, binding)
    attrs = Toybaco::Entitlements.attributes(account)
    purchase = attrs[Toybaco::Growth::PurchaseIntent::KEY]
    raise Invalid unless account.active? && Toybaco::Entitlements.contract_for(account) == binding['contract']
    raise Invalid unless attrs.values_at('toybaco_subscription_id',
                                         'toybaco_stripe_customer_id') == binding.values_at('subscription_id', 'customer_id')
    raise Invalid unless purchase.is_a?(Hash) && purchase.values_at('state', 'nonce', 'subscription_id', 'livemode') ==
                                                 ['complete', binding['purchase_nonce'], binding['subscription_id'], binding['mode'] == 'live']
  end
end
