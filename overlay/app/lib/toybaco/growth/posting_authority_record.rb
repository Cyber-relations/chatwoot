# frozen_string_literal: true

require_relative 'posting_preparation_ack'
require_relative 'posting_authority_state'
require_relative 'posting_paid_upgrade_record'

module Toybaco::Growth::PostingAuthorityRecord
  Record = Toybaco::Growth::PostingPreparationRecord
  FIELDS = %w[version account_id authority_id preparation_request_id preparation_hash ack_hash owner_id
              expected_rails_pointer_hash expected_postiz_pointer_hash expires_at scheduled_posts_per_account revision created_at].freeze
  WIRE_FIELDS = %w[accountId organizationId authorityId preparationRequestId preparationReceiptHash railsAuthorityHash
                   expiresAt scheduledPostsPerAccount expectedPointerHash].freeze

  module_function

  def find(account_id, authority_id, now:)
    row = Toybaco::GrowthPostingAuthority.find_by(account_id: account_id, authority_id: authority_id)
    validate!(row, now: now) if row
    row
  end

  def validate!(row, now:)
    value = row.receipt
    raise Record::Invalid unless value.is_a?(Hash) && value.keys.sort == (fields(value) + ['receipt_hash']).sort && [1, 2].include?(value['version'])

    validate_binding!(row, value)
    validate_hashes!(value)
    raise Record::Invalid unless valid_numbers?(value, now) && %w[pending active stale].include?(row.state)

    validate_times!(row, value, now)
    typed_record(value)&.authority!(row, now: now)

    value
  end

  def fields(value)
    value['version'] == 2 ? FIELDS + typed_record(value)::EXTRA : FIELDS
  end

  def effective_preparation!(row, now:)
    prepared = preparation!(row, now: now)
    typed_record(row.receipt)&.effective(row, prepared, now: now) || prepared
  end

  def typed_record(value)
    return unless value['version'] == 2
    return Toybaco::Growth::PostingPaidUpgradeRecord if value['operation'] == 'paid_upgrade' && !value.key?('kind')

    require_relative 'posting_renewal_authority'
    return Toybaco::Growth::PostingRenewalAuthority if Toybaco::Growth::PostingRenewalAuthority.typed?(value)

    raise Record::Invalid
  end

  def validate_times!(row, value, now)
    raise Record::Invalid unless row.created_at.to_i == value['created_at'] && row.created_at <= now &&
                                 row.updated_at.between?(row.created_at, now)
  end

  def validate_binding!(row, value)
    raise Record::Invalid unless value['receipt_hash'] == Record.digest(value.slice(*fields(value)))
    raise Record::Invalid unless value.values_at('account_id', 'authority_id', 'preparation_request_id') ==
                                 [row.account_id, row.authority_id, row.preparation_request_id]
  end

  def validate_hashes!(value)
    hashes = %w[authority_id preparation_request_id preparation_hash ack_hash receipt_hash revision]
    pointers = %w[expected_rails_pointer_hash expected_postiz_pointer_hash]
    raise Record::Invalid unless hashes.all? { |key| Record.hash?(value[key]) }
    raise Record::Invalid unless pointers.all? { |key| value[key].nil? || Record.hash?(value[key]) }
  end

  def valid_numbers?(value, now)
    %w[account_id owner_id].all? { |key| value[key].is_a?(Integer) && value[key].between?(1, 9_007_199_254_740_991) } &&
      valid_expiry?(value, now) &&
      value['scheduled_posts_per_account'].is_a?(Integer) && value['scheduled_posts_per_account'].between?(1, 10_000)
  end

  def valid_expiry?(value, now)
    value['created_at'].is_a?(Integer) && value['created_at'].between?(1, now.to_i) &&
      value['expires_at'].is_a?(Integer) && value['expires_at'] > value['created_at'] &&
      value['expires_at'] <= 9_007_199_254_740_991
  end

  def preparation!(row, now:)
    value = validate!(row, now: now)
    prepared = Record.find(row.account_id, row.preparation_request_id, now: now)
    raise Record::Invalid unless prepared && prepared.values_at('owner_id', 'receipt_hash') == value.values_at('owner_id', 'preparation_hash')

    prepared
  end

  def wire(row, ack, now:)
    value = validate!(row, now: now)
    raise Record::Invalid unless ack['receipt_hash'] == value['ack_hash']

    { 'accountId' => row.account_id, 'organizationId' => Toybaco::PostizSync.deterministic_organization_id(row.account_id),
      'authorityId' => row.authority_id, 'preparationRequestId' => row.preparation_request_id,
      'preparationReceiptHash' => ack.fetch('response').fetch('preparation').fetch('receiptHash'),
      'railsAuthorityHash' => value['receipt_hash'], 'expiresAt' => value['expires_at'],
      'scheduledPostsPerAccount' => value['scheduled_posts_per_account'], 'expectedPointerHash' => value['expected_postiz_pointer_hash'] }
      .merge(typed_record(value)&.wire_extra(row) || {})
  end
end
