# frozen_string_literal: true

require_relative 'ordinary_renewal_evidence'
require_relative 'ordinary_renewal_receipt'

# Due-time proof for admission stop only. The caller must obtain failure from
# OrdinaryRenewalFact and CAS the same Account/binding/period before and after
# this read. There is no authority grant, void/cancel permission, or mutation.
class Toybaco::Growth::OrdinaryRenewalDueEvidence < Toybaco::Growth::OrdinaryRenewalEvidence
  def initialize(binding:, previous_coverage:, client:, now:)
    raise Invalid unless binding.is_a?(Hash) && previous_coverage.is_a?(Hash) && binding['coverage'] == previous_coverage

    source = { 'binding' => binding, 'previous_coverage' => previous_coverage, 'kind' => 'billing_period' }
    super(source, client: client, now: now)
  end

  def verify!(failure:)
    verify_evidence!('ordinary_renewal_due', failure)
  end

  private

  def validate_period!(id, starts, ends)
    validate_invoice_period!(id, starts, ends)
  end

  def unpaid!(invoice)
    validate_failure!
    evidence = { 'binding' => @binding, 'period' => @period, 'verified_at' => @now.to_i, 'failure' => @failure }
    Toybaco::Growth::OrdinaryRenewalReceipt.failure!(evidence)
    raise Invalid unless @now.to_i >= @failure.fetch('due_at')
    raise Invalid unless Toybaco::Growth::RenewalPayments.new(@client, invoice).idle?

    nil
  end

  def result(_coverage)
    { 'version' => 1, 'kind' => 'ordinary_renewal_due', 'binding' => @binding.except('coverage'),
      'previous_coverage' => previous_coverage, 'period' => @period, 'failure' => @failure,
      'verified_at' => @now.to_i, 'due_at' => @failure.fetch('due_at'), 'execute' => false }
  end
end
