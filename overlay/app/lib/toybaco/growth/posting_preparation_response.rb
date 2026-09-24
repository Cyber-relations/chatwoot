# frozen_string_literal: true

require_relative 'posting_preparation_export'

module Toybaco::Growth::PostingPreparationResponse
  Record = Toybaco::Growth::PostingPreparationRecord
  Invalid = Record::Invalid
  FIELDS = %w[execute organizationId payloadHash preparedAt receiptHash requestId state version].freeze

  module_function

  def validate!(value, request, now:)
    raise Invalid unless value.is_a?(Hash) && value.keys.sort == %w[preparation request_sha256 version] && value['version'] == 2
    raise Invalid unless value['request_sha256'] == Digest::SHA256.hexdigest(JSON.generate(request))

    validate_receipt!(value['preparation'], request.fetch('preparation'), now: now)
    value
  rescue KeyError, TypeError
    raise Invalid
  end

  def validate_receipt!(receipt, input, now:)
    raise Invalid unless receipt.is_a?(Hash) && receipt.keys.sort == FIELDS &&
                         receipt.values_at('version', 'state', 'execute') == [2, 'prepared', false]
    raise Invalid unless receipt['preparedAt'].is_a?(Integer) && receipt['preparedAt'].between?(1, (now.to_r * 1000).to_i + 60_000)

    validate_binding!(receipt, input)
  end

  def validate_binding!(receipt, input)
    raise Invalid unless %w[organizationId requestId].all? { |key| receipt[key] == input[key] }
    raise Invalid unless receipt['payloadHash'] == Record.digest(input) &&
                         receipt['receiptHash'] == Record.digest(receipt.except('receiptHash'))
  end
end
