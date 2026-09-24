# frozen_string_literal: true

module Toybaco::Growth::PostingRenewalSourceValue
  Renewal = Toybaco::Growth::PostingRenewalRecord

  module_function

  def read(row, now)
    return original(row, now) unless Toybaco::Growth::PostingRenewalAuthority.typed?(row.receipt)

    renewal = Toybaco::Growth::PostingRenewalAuthority.renewal!(row, now: now)
    original = Toybaco::Growth::PostingRenewalAuthority.preparation!(row, now: now)
    prepared = Toybaco::Growth::PostingRenewalAuthority.effective_preparation!(row, original, now: now)
    value = { 'binding' => Renewal.new_binding(renewal.receipt), 'kind' => renewal.kind,
              'period' => renewal.receipt.dig('evidence', 'period'),
              'previous_coverage' => renewal.receipt.dig('evidence', 'previous_coverage') }
    value.delete('previous_coverage') if renewal.kind == 'renewal_paid'
    value['recovery'] = renewal.receipt['recovery']
    value['previous_upgrade'] = renewal.receipt['previous_upgrade'] if renewal.kind == 'renewal_grace'

    [value, prepared]
  end

  def original(row, now)
    prepared = Toybaco::Growth::PostingAuthorityRecord.effective_preparation!(row, now: now)
    kind = row.receipt['operation'] == 'paid_upgrade' ? 'paid_upgrade' : 'paid_activation'
    value = { 'binding' => prepared['binding'], 'kind' => kind, 'period' => nil, 'recovery' => prepared['posting_paid_recovery'] }
    value['previous_upgrade'] = Toybaco::Growth::OrdinaryRenewalUpgradeCoverage.reference(row, now: now) if kind == 'paid_upgrade'
    [value, prepared]
  end
end
