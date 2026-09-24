# frozen_string_literal: true

require_relative 'scheduled_grant_upgrade_record'
require_relative 'posting_paid_upgrade_terms'
require_relative 'scheduled_downgrade_invoice'
require_relative 'allowance'

# Called only within the existing Account-locked SubscriptionSync transaction.
# The source, target and every new grant are committed or rolled back together.
class Toybaco::Growth::ScheduledGrantUpgrade
  Record = Toybaco::Growth::ScheduledGrantUpgradeRecord
  Origin = Toybaco::Growth::ScheduledDowngradeRecord
  Terms = Toybaco::Growth::PostingPaidUpgradeTerms
  Invalid = Record::Invalid
  FLAG = 'TOYBACO_SCHEDULED_GRANT_UPGRADE_ENABLED'

  def initialize(account, now: Time.now.utc, environment: ENV)
    @account = account
    @now = now
    @environment = environment
  end

  def prepare!(origin, subscription, target)
    return false unless origin.recovery

    chain = Record.chain(origin, now: @now)
    source = source_binding(origin, chain)
    return false if chain.empty? && target == source['contract']
    return current_target!(source, subscription, target) if target == source['contract']

    Record.current!(@account, source)
    raise Invalid unless @environment[FLAG] == 'true'

    verify_transaction!
    fresh = Terms.target(subscription, { 'binding' => source }, @account, now: @now)
    raise Invalid unless fresh['contract'] == target

    save!(origin, receipt(origin, chain, source, fresh, subscription))
    true
  end

  def promote!(origin, coverage, period, limit)
    rows = Record.chain(origin, now: @now)
    return false if rows.empty?

    value = rows.last.receipt
    raise Invalid unless period == value['period'] && limit == origin.recovery.dig('coverage', 'normal_limit') &&
                         Toybaco::Entitlements.contract_for(@account) == value.dig('target_binding', 'contract') &&
                         coverage.except('current_period_start', 'current_base_limit') == value.dig('target_binding', 'coverage')

    base!(origin, value['base_units'])
    true
  end

  def limit_for(origin, grant)
    rows = Record.chain(origin, now: @now)
    return unless rows.any?

    value = rows.last.receipt
    Record.current!(@account, value['target_binding'])
    base!(origin, value['base_units'])
    verify_grants!(rows)
    grant.units
  end

  def verify_applied!(origin, coverage)
    rows = Record.chain(origin, now: @now)
    return if rows.empty?

    raise Invalid unless coverage == rows.last.receipt.dig('target_binding', 'coverage')

    Record.current!(@account, rows.last.receipt['target_binding'])
    verify_grants!(rows)
  end

  private

  def source_binding(origin, chain)
    chain.last&.receipt&.fetch('target_binding') || origin.recovery['binding'].merge('coverage' => origin.recovery['coverage'])
  end

  def save!(origin, value)
    Toybaco::GrowthScheduledGrantUpgrade.create!(account_id: @account.id, scheduled_downgrade_id: origin.id, grant_id: origin.grant_id,
                                                 parent_hash: value['parent_hash'], operation_id: Record.operation_id(value), receipt: value,
                                                 receipt_hash: Record::Record.digest(value), created_at: @now, updated_at: @now)
  end

  def verify_transaction!
    raise Invalid unless Account.connection.transaction_open? && Account.connection.select_value('SHOW transaction_isolation') == 'read committed'

    current = Toybaco::Growth::PostingPrincipal.locked_account!(@account.id)
    raise Invalid unless current.internal_attributes == @account.internal_attributes && current.status == @account.status
  end

  def current_target!(source, subscription, target)
    # Later normal periods keep the verified contract; this does not grant any
    # same-period upgrade. PaidPeriod still verifies the new paid coverage.
    Record.identity!(@account, source)
    raise Invalid unless Toybaco::Entitlements.contract_for(@account) == target

    expected = [source['subscription_id'], source['customer_id'], source['mode'] == 'live']
    raise Invalid unless subscription.values_at('id', 'customer', 'livemode') == expected &&
                         subscription.dig('metadata', 'toybaco_purchase_nonce') == source['purchase_nonce']

    true
  end

  def receipt(origin, chain, source, target, subscription)
    period = current_period!(origin, source)
    grant = base!(origin)
    grants = grants_for(origin, period)
    { 'version' => 1, 'account_id' => @account.id, 'scheduled_downgrade_id' => origin.id, 'grant_id' => grant.id,
      'parent_hash' => chain.last&.receipt_hash || origin.recovery_hash, 'source_binding' => source, 'target_binding' => target,
      'period' => period, 'grants_hash' => Record::Record.digest(grants.map(&:attributes)),
      'additional_units' => additional_units(source, target, period, grants), 'base_units' => grant.units, 'created_at' => @now.to_i,
      'subscription_hash' => Toybaco::Growth::ScheduledDowngradeInvoice.subscription_hash(subscription),
      'invoice_hash' => Record::Record.digest(subscription.fetch('latest_invoice').except('hosted_invoice_url', 'invoice_pdf')) }
  end

  def current_period!(origin, source)
    period = Origin.period(origin.receipt)
    raise Invalid unless @now.to_i.between?(period['starts_at'], period['ends_at'] - 1)
    raise Invalid unless source['coverage'].slice('term_start', 'term_end',
                                                  'anchor') == origin.recovery['coverage'].slice('term_start', 'term_end', 'anchor')

    period
  end

  def base!(origin, units = nil)
    grant = Toybaco::GrowthAiGrant.find_by(id: origin.grant_id, account_id: @account.id)
    period = Origin.period(origin.receipt)
    raise Invalid unless grant && grant.source == 'included' && !grant.revoked_at && grant.source_key == Origin.key(origin.receipt) &&
                         period.values_at('starts_at', 'ends_at') == [grant.starts_at.to_i, grant.ends_at.to_i]

    verify_base_units!(grant, units)

    grant
  end

  def verify_base_units!(grant, units)
    raise Invalid if units && grant.units != units
  end

  def grants_for(origin, period)
    prefix = "paid:#{origin.receipt.dig('binding', 'subscription_id')}:#{period['starts_at']}:"
    Toybaco::GrowthAiGrant.where(account_id: @account.id, source: 'included').where('left(source_key, ?) = ?', prefix.length, prefix).order(:id).to_a
  end

  def additional_units(source, target, period, grants)
    remaining = [period['ends_at'] - [target.dig('coverage', 'paid_at'), period['starts_at']].max, 0].max
    Toybaco::Growth::Allowance.upgrade(old_limit: source.dig('coverage', 'normal_limit'), new_limit: target.dig('coverage', 'normal_limit'),
                                       granted: grants.sum(&:units), period_seconds: period['ends_at'] - period['starts_at'],
                                       remaining_seconds: remaining)
  end

  def verify_grants!(rows)
    rows.each do |row|
      value = row.receipt
      next if value['additional_units'].zero?

      prefix = "paid:#{value.dig('target_binding', 'subscription_id')}:#{value.dig('period', 'starts_at')}:"
      grant = Toybaco::GrowthAiGrant.find_by(account_id: @account.id, source: 'included',
                                             source_key: "#{prefix}upgrade:#{value.dig('target_binding', 'coverage', 'invoice_id')}")
      raise Invalid unless grant && !grant.revoked_at && grant.units == value['additional_units'] &&
                           value['period'].values_at('starts_at', 'ends_at') == [grant.starts_at.to_i, grant.ends_at.to_i]
    end
  end
end
