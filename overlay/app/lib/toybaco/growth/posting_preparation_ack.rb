# frozen_string_literal: true

require_relative 'posting_preparation_protocol'

module Toybaco::Growth::PostingPreparationAck
  Record = Toybaco::Growth::PostingPreparationRecord
  FIELDS = %w[account_id confirmed_at owner_id preparation_hash receipt_hash request_id response version].freeze

  module_function

  def find(prepared, payload, now:)
    row = Toybaco::GrowthPostingPreparationAck.find_by(account_id: prepared['account_id'], request_id: prepared['request_id'])
    return unless row

    value = row.receipt
    validate!(value, prepared, payload, now: now)
    raise Record::Invalid unless row.created_at == row.updated_at && row.created_at.to_i == value['confirmed_at']

    value
  end

  def validate!(value, prepared, payload, now:)
    raise Record::Invalid unless header?(value)
    raise Record::Invalid unless value.values_at('account_id', 'request_id', 'owner_id', 'preparation_hash') ==
                                 prepared.values_at('account_id', 'request_id', 'owner_id', 'receipt_hash')
    raise Record::Invalid unless value['confirmed_at'].is_a?(Integer) && value['confirmed_at'].between?(prepared['prepared_at'], now.to_i)

    Toybaco::Growth::PostingPreparationResponse.validate!(value['response'], payload, now: Time.at(value['confirmed_at']).utc)
    value
  end

  def header?(value)
    value.is_a?(Hash) && value.keys.sort == FIELDS && value['version'] == 2 &&
      value['receipt_hash'] == Record.digest(value.except('receipt_hash'))
  end

  def save!(prepared, payload, response, now:)
    previous = find(prepared, payload, now: now)
    if previous
      raise Record::Invalid unless previous['response'] == response

      return previous
    end

    value = prepared.slice('account_id', 'request_id', 'owner_id').merge('version' => 2, 'preparation_hash' => prepared['receipt_hash'],
                                                                         'response' => response, 'confirmed_at' => now.to_i)
    value['receipt_hash'] = Record.digest(value)
    validate!(value, prepared, payload, now: now)
    Toybaco::GrowthPostingPreparationAck.create!(account_id: value['account_id'], request_id: value['request_id'], receipt: value,
                                                 created_at: now, updated_at: now)
    value
  end
end
