# frozen_string_literal: true

# Structural verification of the immutable provider evidence. This is not a
# substitute for retrieving current Stripe objects before handoff.
module Toybaco::Growth::OrdinaryRenewalReceipt
  Record = Toybaco::Growth::PostingPreparationRecord
  FIELDS = %w[version kind binding previous_coverage period coverage failure verified_at expires_at].freeze
  PERIOD = %w[invoice_id term_start term_end].freeze
  FAILURE = %w[mode subscription_id customer_id invoice_id operation_id fact_id fact_hash first_failed_at due_at].freeze

  module_function

  def validate!(value)
    evidence = value['evidence']
    raise Record::Invalid unless evidence.is_a?(Hash) && evidence.keys.sort == FIELDS.sort && evidence['version'] == 1

    validate_kind!(evidence, value)
    raise Record::Invalid unless evidence['binding'] == value.fetch('source_binding').except('coverage')

    period!(evidence, value)
    value['kind'] == 'renewal_grace' ? grace!(evidence, value) : paid!(evidence)
  end

  def validate_kind!(evidence, value)
    raise Record::Invalid unless evidence['kind'] == value['kind'] && %w[renewal_grace renewal_paid].include?(value['kind'])
  end

  def period!(evidence, value)
    period = evidence['period']
    previous = evidence['previous_coverage']
    raise Record::Invalid unless period.is_a?(Hash) && period.keys.sort == PERIOD.sort && previous.is_a?(Hash)

    period_shape!(period, previous)
    previous!(evidence, value)
  end

  def period_shape!(period, previous)
    raise Record::Invalid unless period['invoice_id'].is_a?(String) && /\Ain_[A-Za-z0-9]+\z/.match?(period['invoice_id'])

    period_times!(period, previous)
  end

  def period_times!(period, previous)
    raise Record::Invalid unless period.values_at('term_start', 'term_end').all? { |time| time.is_a?(Integer) && time.positive? }
    raise Record::Invalid unless period['term_start'] < period['term_end'] && previous['term_end'] == period['term_start']
  end

  def previous!(evidence, value)
    previous = evidence['previous_coverage']
    binding = evidence['binding']
    raise Record::Invalid unless previous == value.dig('source_binding', 'coverage')
    raise Record::Invalid unless previous['subscription_id'] == binding['subscription_id'] &&
                                 previous['paid_at'].is_a?(Integer) && previous['paid_at'] < previous['term_end']
    raise Record::Invalid unless previous.slice('plan_id', 'plan_version', 'cycle', 'stripe_price_id') ==
                                 binding.fetch('contract').slice('plan_id', 'plan_version', 'cycle', 'stripe_price_id')

    source_type!(evidence, value)
  end

  def source_type!(evidence, value)
    raise Record::Invalid unless %w[paid_activation paid_upgrade renewal_grace renewal_paid].include?(value['source_kind'])

    return unless value['source_kind'] == 'renewal_grace'
    raise Record::Invalid unless value['kind'] == 'renewal_paid' && value['source_period'] == evidence['period']
  end

  def failure!(evidence)
    failure = evidence['failure']
    raise Record::Invalid unless failure.is_a?(Hash) && failure.keys.sort == FAILURE.sort
    raise Record::Invalid unless failure.slice('mode', 'subscription_id', 'customer_id') ==
                                 evidence.fetch('binding').slice('mode', 'subscription_id', 'customer_id') &&
                                 failure['invoice_id'] == evidence.dig('period', 'invoice_id')

    failure_times!(failure, evidence)
  end

  def failure_times!(failure, evidence)
    fields = %w[first_failed_at due_at operation_id fact_id]
    raise Record::Invalid unless fields.all? { |key| failure[key].is_a?(Integer) && failure[key].positive? } && Record.hash?(failure['fact_hash'])
    raise Record::Invalid unless failure['due_at'] == failure['first_failed_at'] + 604_800 &&
                                 failure['first_failed_at'].between?(evidence.dig('period', 'term_start'), evidence['verified_at'])
  end

  def grace!(evidence, value)
    failure!(evidence)
    raise Record::Invalid unless evidence['coverage'].nil? && value['source_kind'] != 'renewal_grace'
    raise Record::Invalid unless evidence['expires_at'] == [evidence.dig('failure', 'due_at'), evidence.dig('period', 'term_end')].min
  end

  def paid!(evidence)
    coverage = evidence['coverage']
    raise Record::Invalid unless coverage.is_a?(Hash) && coverage.slice(*PERIOD) == evidence['period']
    raise Record::Invalid unless coverage['paid_at'].is_a?(Integer) &&
                                 coverage['paid_at'].between?(evidence.dig('period', 'term_start'), evidence['verified_at'])
    raise Record::Invalid unless evidence['expires_at'] == evidence.dig('period', 'term_end')

    failure!(evidence) if evidence['failure']
  end
end
