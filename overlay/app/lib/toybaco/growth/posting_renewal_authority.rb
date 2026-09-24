# frozen_string_literal: true

require_relative 'posting_renewal_record'
require_relative 'posting_renewal_target'
require_relative 'posting_renewal_source_value'

# Dedicated immutable ordinary-renewal authority, shared by execution and read-only classification.
module Toybaco::Growth::PostingRenewalAuthority
  Authority = Toybaco::Growth::PostingAuthorityRecord
  Renewal = Toybaco::Growth::PostingRenewalRecord
  Record = Toybaco::Growth::PostingPreparationRecord
  EXTRA = %w[kind source_authority_id source_authority_hash continuation_request_id continuation_hash binding principal_hash].freeze

  module_function

  def typed?(value)
    value.is_a?(Hash) && value['version'] == 2 && %w[renewal_grace renewal_paid].include?(value['kind']) && !value.key?('operation')
  end

  def effective_preparation!(row, original, now:)
    renewal = renewal!(row, now: now)
    value = renewal.receipt
    original.merge('binding' => Renewal.new_binding(value), 'principal' => value.fetch('principal'),
                   'contract_hash' => value.fetch('contract_hash'), 'posting_renewal' => value)
  end

  def authority!(row, now:)
    renewal!(row, now: now)
  end

  def effective(row, original, now:)
    effective_preparation!(row, original, now: now)
  end

  def wire_extra(row)
    target_wire(Toybaco::GrowthPostingRenewal.find_by!(account_id: row.account_id, request_id: row.receipt.fetch('continuation_request_id')))
      .except(*Authority::WIRE_FIELDS)
  end

  def follows_execution?(execution, previous, now:)
    require_relative 'posting_renewal_execution_proof'
    Toybaco::Growth::PostingRenewalExecutionProof.new(execution, previous, now: now).valid?
  end

  def source!(account_id, authority_id, now:, environment:)
    row = Toybaco::GrowthPostingAuthority.find_by(account_id: account_id, authority_id: authority_id)
    raise Record::Invalid unless row && row.state == 'active'

    value, prepared = source_value!(row, now)
    original = preparation!(row, now: now)
    ack = ack!(row, original, environment, now)
    wire = Authority.wire(row, ack, now: now)
    validate_remote!(row, wire)
    value.merge('authority_id' => row.authority_id, 'authority_hash' => Record.digest(wire),
                'rails_authority_hash' => row.receipt.fetch('receipt_hash'), 'prepared' => prepared,
                'preparation_receipt_hash' => ack.dig('response', 'preparation', 'receiptHash'))
  end

  def source_value!(row, now)
    Toybaco::Growth::PostingRenewalSourceValue.read(row, now)
  end

  def ack!(row, prepared, environment, now)
    protocol = Toybaco::Growth::PostingPreparationProtocol
    payload = protocol.request(prepared, row.account_id, config: protocol.configuration(environment), now: now)
    ack = Toybaco::Growth::PostingPreparationAck.find(prepared, payload, now: now)
    raise Record::Invalid unless ack && ack['receipt_hash'] == row.receipt['ack_hash']

    ack
  end

  def validate_remote!(row, wire)
    remote = row.postiz_receipt
    raise Record::Invalid unless remote.is_a?(Hash) && remote.values_at('authorityId', 'authorityHash', 'state', 'current', 'execute') ==
                                                       [row.authority_id, Record.digest(wire), 'ready', true,
                                                        false] && Record.hash?(remote['pointerHash'])
  end

  def renewal!(row, now:)
    value = row.receipt
    validate_header!(value)
    Authority.validate_times!(row, value, now)
    continuation!(row, value, now)
  end

  def validate_header!(value)
    raise Record::Invalid unless value.is_a?(Hash) && typed?(value) && value.keys.sort == (Authority::FIELDS + EXTRA + ['receipt_hash']).sort
    raise Record::Invalid unless value['receipt_hash'] == Record.digest(value.except('receipt_hash'))
  end

  def continuation!(row, value, now)
    record = Renewal.find(row.account_id, value['continuation_request_id'], now: now)
    unless record && record.target_authority_id == row.authority_id && record.receipt['receipt_hash'] == value['continuation_hash']
      raise Record::Invalid
    end
    raise Record::Invalid unless record.state == 'ready' && value == target_receipt(record)

    record
  end

  def preparation!(row, now:)
    value = Record.find(row.account_id, row.preparation_request_id, now: now)
    raise Record::Invalid unless value && value['receipt_hash'] == row.receipt['preparation_hash'] && value['owner_id'] == row.receipt['owner_id']

    value
  end

  def create!(renewal, source, now:)
    previous = Toybaco::GrowthPostingAuthority.find_by(account_id: renewal.account_id, authority_id: renewal.target_authority_id)
    value = target_receipt(renewal, source: source)
    if previous
      raise Record::Invalid unless previous.receipt == value

      return previous
    end

    Toybaco::GrowthPostingAuthority.create!(account_id: renewal.account_id, authority_id: renewal.target_authority_id,
                                            preparation_request_id: value['preparation_request_id'], receipt: value,
                                            created_at: now, updated_at: now)
  end

  def target_wire(renewal)
    Toybaco::Growth::PostingRenewalTarget.wire(renewal)
  end

  def target_receipt(renewal, source: nil)
    Toybaco::Growth::PostingRenewalTarget.receipt(renewal, source: source)
  end
end
