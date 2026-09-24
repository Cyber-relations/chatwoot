# frozen_string_literal: true

# Bounded paid chains may end at one strictly verified ordinary paid renewal.
module Toybaco::Growth::PostingPaidRenewalLink
  Record = Toybaco::Growth::PostingPreparationRecord

  def paid?(value)
    value.is_a?(Hash) && value['version'] == 2 && value['operation'] == 'paid_upgrade'
  end

  def renewal_paid?(value)
    value.is_a?(Hash) && value['version'] == 2 && value['kind'] == 'renewal_paid' && !value.key?('operation')
  end

  def validate_anchor!(row, now:)
    if renewal_paid?(row.receipt)
      Toybaco::Growth::PostingRenewalAuthority.renewal!(row, now: now)
    elsif row.receipt['version'] == 1
      Toybaco::Growth::PostingAuthorityRecord.validate!(row, now: now)
    else
      raise Record::Invalid
    end
  end

  def validate_renewal_parent!(previous, current, now)
    validate_anchor!(previous, now: now)
    validate_parent_link!(previous, current, now)
  end

  def renewal_recovery(row, now:)
    anchor = validate_chain!(row, now: now)
    return unless renewal_paid?(anchor.receipt)

    Toybaco::Growth::PostingRenewalAuthority.renewal!(anchor, now: now).receipt['recovery']&.deep_dup
  end

  def renewal_execution?(current, execution, previous, now)
    return false unless current && renewal_paid?(current.receipt)

    validate_anchor!(current, now: now)
    source = execution.merge('authorityId' => current.authority_id, 'authorityHash' => current.postiz_receipt.fetch('authorityHash'),
                             'railsAuthorityHash' => current.receipt.fetch('receipt_hash'))
    Toybaco::Growth::PostingRenewalAuthority.follows_execution?(source, previous, now: now)
  end
end
