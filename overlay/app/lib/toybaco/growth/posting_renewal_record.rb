# frozen_string_literal: true

require_relative 'posting_authority_record'
require_relative 'ordinary_renewal_receipt'

# One immutable request per invoice/type; a new request cannot re-arm an old
# authority, schedule, root or provider operation after an uncertain outcome.
module Toybaco::Growth::PostingRenewalRecord
  Record = Toybaco::Growth::PostingPreparationRecord
  FIELDS = %w[version account_id request_id source_authority_id source_authority_hash source_rails_hash target_authority_id kind
              expected_rails_pointer_hash expected_postiz_pointer_hash owner_id principal principal_hash contract_hash
              preparation_request_id preparation_hash preparation_receipt_hash source_binding source_kind source_period previous_upgrade
              posting evidence recovery created_at].freeze
  STATES = %w[prepared transferring applied ready].freeze

  module_function

  def find(account_id, request_id, now:)
    row = Toybaco::GrowthPostingRenewal.find_by(account_id: account_id, request_id: request_id)
    validate!(row, now: now) if row
    row
  end

  def validate!(row, now:)
    value = row&.receipt
    validate_header!(value)
    raise Record::Invalid unless value['receipt_hash'] == Record.digest(value.slice(*FIELDS)) && STATES.include?(row.state)

    validate_identity!(row, value)
    validate_evidence!(value, now)
    validate_phase!(row)
    raise Record::Invalid unless row.created_at.to_i == value['created_at'] && row.updated_at.between?(row.created_at, now)

    value
  end

  def validate_phase!(row)
    return if %w[prepared transferring].include?(row.state)

    raise Record::Invalid unless Record.hash?(row.rails_pointer_hash) && row.postiz_receipt.is_a?(Hash)

    require_relative 'posting_renewal_protocol'
    protocol = Toybaco::Growth::PostingRenewalProtocol
    protocol.validate_receipt!(row.postiz_receipt, protocol.exchange_payload(row, 'prepare'))
    return unless row.state == 'ready'

    protocol.validate_receipt!(row.confirm_receipt, protocol.exchange_payload(row, 'confirm'))
    raise Record::Invalid unless row.confirm_receipt.except('requestHash', 'state') == row.postiz_receipt.except('requestHash', 'state')
  end

  def validate_header!(value)
    raise Record::Invalid unless value.is_a?(Hash) && value.keys.sort == (FIELDS + ['receipt_hash']).sort && value['version'] == 1
  end

  def validate_principal!(value)
    raise Record::Invalid unless value['principal'].is_a?(Hash) && Record.digest(value['principal']) == value['principal_hash']
  end

  def validate_identity!(row, value)
    validate_principal!(value)
    fields = %w[account_id request_id source_authority_id target_authority_id kind]
    raise Record::Invalid unless value.slice(*fields) == row.attributes.slice(*fields)

    hashes = %w[request_id source_authority_id source_authority_hash source_rails_hash target_authority_id principal_hash contract_hash
                preparation_request_id preparation_hash preparation_receipt_hash expected_rails_pointer_hash expected_postiz_pointer_hash]
    raise Record::Invalid unless hashes.all? { |key| Record.hash?(value[key]) } && value['source_authority_id'] != value['target_authority_id']
    raise Record::Invalid unless row.attributes.values_at('mode', 'subscription_id', 'invoice_id') ==
                                 [value.dig('evidence', 'binding', 'mode'), value.dig('evidence', 'binding', 'subscription_id'),
                                  value.dig('evidence', 'period', 'invoice_id')]
  end

  def validate_evidence!(value, now)
    evidence = value['evidence']
    Toybaco::Growth::OrdinaryRenewalReceipt.validate!(value)
    validate_times!(value, evidence, now)
    raise Record::Invalid unless value['owner_id'].is_a?(Integer) && value['owner_id'].positive?
  end

  def validate_times!(value, evidence, now)
    times = [value['created_at'], evidence['verified_at'], evidence['expires_at']]
    raise Record::Invalid unless times.all? { |time| time.is_a?(Integer) && time.positive? } && times[0] <= now.to_i &&
                                 times[1] <= times[0] && times[2] > times[0]
  end

  def target_id(account_id, request_id)
    Record.digest('purpose' => 'posting-renewal-v1', 'account_id' => account_id, 'request_id' => request_id)
  end

  def new_binding(value)
    evidence = value.fetch('evidence')
    coverage = evidence['coverage'] || evidence.fetch('previous_coverage')
    evidence.fetch('binding').merge('coverage' => coverage)
  end
end
