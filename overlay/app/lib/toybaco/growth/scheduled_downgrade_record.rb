# frozen_string_literal: true

require_relative 'posting_preparation_record'

module Toybaco::Growth::ScheduledDowngradeRecord
  Record = Toybaco::Growth::PostingPreparationRecord
  Invalid = Record::Invalid

  module_function

  FIELDS = %w[account_id binding failure reservation principal version cause period].freeze
  FAILURE_FIELDS = %w[mode subscription_id customer_id invoice_id operation_id fact_id fact_hash first_failed_at due_at].freeze
  RECOVERY_FIELDS = %w[version kind binding previous_coverage period coverage failure verified_at expires_at subscription_hash invoice_hash].freeze

  def validate!(row, now: Time.now.utc)
    value = row.receipt
    shape!(row, value)
    times!(row, value, now)
    recovery!(row, value, now)
    row
  end

  def shape!(row, value)
    hash_keys!(value, FIELDS)
    raise Invalid unless value.values_at('version', 'cause', 'account_id') == [1, 'scheduled_downgrade', row.account_id] &&
                         row.receipt_hash == Record.digest(value)

    failure = value['failure']
    hash_keys!(failure, FAILURE_FIELDS)
    raise Invalid unless failure['operation_id'] == row.renewal_operation_id && Record.hash?(failure['fact_hash'])

    binding!(value, failure)
  end

  def hash_keys!(value, fields)
    raise Invalid unless value.is_a?(Hash) && value.keys.sort == fields.sort
  end

  def binding!(value, failure)
    binding = value.fetch('binding')
    hash_keys!(binding, %w[contract coverage customer_id mode purchase_nonce subscription_id])
    raise Invalid unless failure.values_at('subscription_id', 'customer_id', 'mode') == binding.values_at('subscription_id', 'customer_id', 'mode')

    reservation!(value, failure)
  end

  def reservation!(value, failure)
    reservation = value.fetch('reservation')
    hash_keys!(reservation, %w[operation period_end period_start receipt_hash schedule_hash target])
    raise Invalid unless %w[receipt_hash schedule_hash].all? { |key| Record.hash?(reservation[key]) }

    period = value.fetch('period')
    hash_keys!(period, %w[invoice_id term_end term_start])
    raise Invalid unless period.values_at('invoice_id', 'term_start', 'term_end') ==
                         [failure['invoice_id'], reservation['period_start'], reservation['period_end']]
  end

  def times!(row, value, now)
    first, due = value.fetch('failure').values_at('first_failed_at', 'due_at')
    starts, ends = value.fetch('period').values_at('term_start', 'term_end')
    positive_times!(first, due, starts, ends)
    raise Invalid unless due == first + 604_800 &&
                         starts <= first && first < ends && row.created_at.to_i >= first && row.created_at.to_i < [due, ends].min

    record_times!(row, now)
  end

  def record_times!(row, now)
    raise Invalid unless row.created_at <= now && row.updated_at.between?(row.created_at, now)
  end

  def recovery!(row, value, now)
    raise Invalid unless row.recovery.nil? == row.recovery_hash.nil?
    return unless row.recovery

    recovery = row.recovery
    hash_keys!(recovery, RECOVERY_FIELDS)
    raise Invalid unless row.recovery_hash == Record.digest(recovery) && recovery.values_at('version', 'kind') == [1, 'scheduled_downgrade_paid']

    recovery_binding!(recovery, value)
    recovery_coverage!(recovery, value, now)
  end

  def recovery_binding!(recovery, value)
    raise Invalid unless recovery.values_at('failure', 'period', 'previous_coverage') ==
                         [value['failure'], value['period'], value.dig('binding', 'coverage')]

    target = value.dig('reservation', 'target')
    raise Invalid unless recovery['binding'] == value.fetch('binding').except('coverage').merge('contract' => target) &&
                         %w[subscription_hash invoice_hash].all? { |key| Record.hash?(recovery[key]) }
  end

  def recovery_coverage!(recovery, value, now)
    target = value.dig('reservation', 'target')
    coverage = recovery['coverage']
    raise Invalid unless coverage.is_a?(Hash) && coverage.slice(*value.fetch('period').keys) == value['period'] &&
                         coverage.slice('plan_id', 'plan_version', 'cycle',
                                        'stripe_price_id') == target.slice('plan_id', 'plan_version', 'cycle', 'stripe_price_id')
    raise Invalid unless coverage['subscription_id'] == value.dig('binding', 'subscription_id') &&
                         coverage['normal_limit'] == target.dig('entitlements', 'limits', 'ai_generations')

    recovery_times!(recovery, value, now)
  end

  def positive_times!(*times)
    raise Invalid unless times.all? { |time| time.is_a?(Integer) && time.positive? }
  end

  def recovery_times!(recovery, value, now)
    verified = recovery['verified_at']
    paid = recovery.dig('coverage', 'paid_at')
    positive_times!(verified, paid)
    raise Invalid unless paid.between?(value.dig('failure', 'first_failed_at'), verified) &&
                         verified <= now.to_i && recovery['expires_at'] == value.dig('period', 'term_end')
  end

  def period(value)
    period = value.fetch('period')
    return { 'starts_at' => period['term_start'], 'ends_at' => period['term_end'] } if value.dig('binding', 'contract', 'cycle') == 'month'

    coverage = value.dig('binding', 'coverage')
    Toybaco::Growth::MonthlyWindow.new(anchor: Time.at(coverage.fetch('anchor')).utc, now: Time.at(period.fetch('term_start')).utc,
                                       ends_at: Time.at(period.fetch('term_end')).utc).current || raise(Invalid)
  end

  def key(value, period = self.period(value))
    "paid:#{value.dig('binding', 'subscription_id')}:#{period.fetch('starts_at')}:base"
  end
end
