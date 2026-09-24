# frozen_string_literal: true

require_relative 'scheduled_downgrade_record'
require_relative 'allowance'
require_relative 'monthly_window'
require_relative 'scheduled_grant_upgrade'

# Preserve the old row and outstanding reservations. The paid target is an
# admission cap, independently of physical units needed for accepted history.
class Toybaco::Growth::ScheduledDowngradeGrace
  Record = Toybaco::Growth::ScheduledDowngradeRecord
  Invalid = Record::Invalid

  def self.validate!(row, now: Time.now.utc)
    Record.validate!(row, now: now)
  end

  def initialize(account, now: Time.now.utc)
    @account = account
    @now = now
  end

  def row
    failure = Toybaco::Entitlements.attributes(@account)[Toybaco::Growth::RenewalGrace::FAILURE_KEY]
    return active_grant_origin unless failure.is_a?(Hash) && failure['cause'] == 'scheduled_downgrade'

    found = Toybaco::GrowthScheduledDowngrade.find_by(account_id: @account.id, renewal_operation_id: failure.fetch('operation_id'))
    raise Invalid unless found

    Record.validate!(found, now: @now)
  end

  def context
    current = row
    return unless current && !current.recovery && source_current?(current.receipt)

    failure = current.receipt.fetch('failure')
    operation = Toybaco::RenewalOperation.find(current.renewal_operation_id)
    raise Invalid unless operation.first_fact_id == failure['fact_id'] && operation.first_failed_at.to_i == failure['first_failed_at'] &&
                         operation.due_at.to_i == failure['due_at']

    grace_context(current.receipt, failure)
  end

  def refresh!
    Toybaco::Growth::RenewalGrace.new(@account, now: @now).refresh!
  end

  def paid_ready?(subscription, target)
    current = row
    return true unless current
    return true if Toybaco::Growth::ScheduledGrantUpgrade.new(@account, now: @now).prepare!(current, subscription, target)
    return true if already_applied?(current, target)

    require_relative 'scheduled_downgrade_invoice'
    raise Invalid unless current.recovery && current.receipt.dig('reservation', 'target') == target &&
                         current.recovery['subscription_hash'] == Toybaco::Growth::ScheduledDowngradeInvoice.subscription_hash(subscription)

    true
  end

  def promote!(coverage, period, limit)
    current = row
    return false unless current && period == Record.period(current.receipt)

    return true if Toybaco::Growth::ScheduledGrantUpgrade.new(@account, now: @now).promote!(current, coverage, period, limit)

    paid_terms!(current, coverage, limit)
    grant = Toybaco::GrowthAiGrant.find_by(account_id: @account.id, id: current.grant_id)
    raise Invalid unless grant && grant.source_key == Record.key(current.receipt, period) && !grant.revoked_at

    units = paid_units!(grant, limit)
    grant.update!(source: 'included', units: units, starts_at: Time.at(period.fetch('starts_at')).utc, ends_at: Time.at(period.fetch('ends_at')).utc)
    true
  end

  def limit_for(grant)
    current = Toybaco::GrowthScheduledDowngrade.find_by(account_id: @account.id, grant_id: grant.id)
    return grant.units unless current&.recovery

    Record.validate!(current, now: @now)
    raise Invalid unless grant.source == 'included' && grant.source_key == Record.key(current.receipt)

    upgraded = Toybaco::Growth::ScheduledGrantUpgrade.new(@account, now: @now).limit_for(current, grant)
    upgraded || current.recovery.fetch('coverage').fetch('normal_limit')
  end

  def verify_upgrade!(coverage, period)
    current = row
    return unless current && period == Record.period(current.receipt)

    Toybaco::Growth::ScheduledGrantUpgrade.new(@account, now: @now).verify_applied!(current, coverage)
  end

  private

  def active_grant_origin
    return unless Toybaco::Entitlements.contract_for(@account)&.dig('entitlements', 'ai_meter') == Toybaco::GrowthTerms::METER

    ids = Toybaco::GrowthAiGrant.where(account_id: @account.id, source: %w[included grace], revoked_at: nil)
                                .where('starts_at <= ? AND ends_at > ?', @now, @now).select(:id)
    rows = Toybaco::GrowthScheduledDowngrade.where(account_id: @account.id, grant_id: ids).limit(2).to_a
    raise Invalid if rows.length > 1

    Record.validate!(rows.first, now: @now) if rows.one?
  end

  def source_current?(value)
    binding = value.fetch('binding')
    return false unless @account.active? && Toybaco::Entitlements.contract_for(@account) == binding['contract']

    attrs = Toybaco::Entitlements.attributes(@account)
    attrs['toybaco_subscription_id'] == binding['subscription_id'] && attrs['toybaco_stripe_customer_id'] == binding['customer_id'] &&
      attrs[Toybaco::Growth::PaidPeriod::KEY]&.except('current_period_start', 'current_base_limit') == binding['coverage']
  end

  def grace_context(value, failure)
    period = Record.period(value)
    { 'key' => Record.key(value, period), 'starts_at' => failure['first_failed_at'], 'ends_at' => [failure['due_at'], period['ends_at']].min,
      'units' => Toybaco::Growth::Allowance.grace(limit: value.dig('binding', 'coverage', 'normal_limit'),
                                                  period_seconds: period['ends_at'] - period['starts_at']) }
  end

  def already_applied?(current, target)
    current.recovery && Toybaco::Entitlements.contract_for(@account) == current.receipt.dig('reservation', 'target') &&
      target == current.receipt.dig('reservation', 'target')
  end

  def paid_terms!(current, coverage, limit)
    raise Invalid unless current.recovery && current.recovery['coverage'] == coverage.except('current_period_start', 'current_base_limit') &&
                         limit == coverage.fetch('normal_limit') &&
                         current.receipt.dig('reservation', 'target') == Toybaco::Entitlements.contract_for(@account)
  end

  def paid_units!(grant, limit)
    raise Invalid unless %w[grace included].include?(grant.source)

    reserved = Toybaco::GrowthAiOperation.where(account_id: @account.id, grant_id: grant.id, state: 'reserved').count
    units = grant.source == 'included' ? grant.units : [limit, grant.used + reserved].max
    raise Invalid unless grant.used + reserved <= units && limit <= units

    units
  end
end
