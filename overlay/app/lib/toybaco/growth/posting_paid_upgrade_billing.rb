# frozen_string_literal: true

# A recovered failure remains an immutable fact. Only a validated ordinary paid
# anchor may carry its exact recovery through a same-period paid upgrade.
module Toybaco::Growth::PostingPaidUpgradeBilling
  Execution = Toybaco::Growth::PostingExecutionContext

  module_function

  def target_hash(binding)
    attrs = @account.internal_attributes.merge('toybaco_contract' => binding['contract'])
    Execution.digest(Execution.binding(@account.status, attrs))
  end

  def paid_upgrade_billing_blocked?(attrs)
    Toybaco::Growth::PostingPaidUpgradeBilling.blocked?(attrs, recovery: @posting_paid_recovery, environment: @environment) do |candidate|
      blocked_billing?(candidate)
    end
  end

  def blocked?(attrs, recovery:, environment:)
    failure_key = Toybaco::Growth::RenewalSettlement::FAILURE_KEY
    return yield(attrs) unless attrs.key?(failure_key)
    return true unless recovered?(attrs[failure_key], attrs, recovery, environment)

    yield attrs.except(failure_key)
  end

  def recovered?(failure, attrs, proof, environment)
    return false unless proof.is_a?(Hash) && proof.keys.sort == %w[coverage failure period] && failure.is_a?(Hash)

    fact = proof['failure']
    period = proof['period']
    coverage = proof['coverage']
    return false unless [fact, period, coverage].all?(Hash)
    return false unless fact.values_at('mode', 'subscription_id', 'customer_id') ==
                        [environment['TOYBACO_STRIPE_MODE'], attrs['toybaco_subscription_id'], attrs['toybaco_stripe_customer_id']]

    failure_matches?(failure, fact, period, coverage)
  end

  def failure_matches?(failure, fact, period, coverage)
    failure.values_at('subscription_id', 'invoice_id', 'first_failed_at', 'grace_ends_at') ==
      fact.values_at('subscription_id', 'invoice_id', 'first_failed_at', 'due_at') &&
      failure.values_at('term_start', 'term_end') == period.values_at('term_start', 'term_end') &&
      coverage.slice('invoice_id', 'term_start', 'term_end') == period && coverage['subscription_id'] == fact['subscription_id']
  end
end
