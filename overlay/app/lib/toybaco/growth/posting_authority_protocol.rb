# frozen_string_literal: true

require_relative 'posting_preparation_protocol'
require_relative 'posting_authority_record'

module Toybaco::Growth::PostingAuthorityProtocol
  Invalid = Toybaco::Growth::PostingPreparationRecord::Invalid
  Record = Toybaco::Growth::PostingPreparationRecord
  PATH = '/toybaco/internal/posting-authority'
  PURPOSE = 'toybaco-posting-authority-v1'
  HEADER = 'X-Toybaco-Authority-Signature'
  MAX_BYTES = 65_536
  RESPONSE_FIELDS = %w[authorityId authorityHash organizationId state pointerHash current execute].freeze

  module_function

  def configuration(environment)
    raise Invalid unless environment['TOYBACO_POSTING_AUTHORITY_ENABLED'] == 'true'

    config = Toybaco::Growth::PostingPreparationProtocol.configuration(environment)
    config.merge(key: OpenSSL::HMAC.digest('SHA256', environment.fetch('TOYBACO_OIDC_CLIENT_SECRET'), PURPOSE))
  end

  def request(authority, operation:, config:)
    raise Invalid unless %w[activate confirm
                            status].include?(operation) && valid_wire?(authority, operation)

    { 'version' => 1, 'issuer' => config.fetch(:issuer), 'audience' => config.fetch(:origin), 'mode' => config.fetch(:mode),
      'operation' => operation, 'authority' => authority.deep_dup }
  end

  def valid_wire?(authority, operation)
    fields = Toybaco::Growth::PostingAuthorityRecord::WIRE_FIELDS
    return authority.keys.sort == fields.sort unless authority.key?('kind')

    operation == 'status' && %w[paid_upgrade renewal_grace renewal_paid].include?(authority['kind']) &&
      authority.keys.sort == (fields + Toybaco::Growth::PostingPaidUpgradeInventory::EXTRA).sort
  end

  def signature(raw, key:, now:, direction:)
    stamp = now.to_i.to_s
    digest = OpenSSL::HMAC.hexdigest('SHA256', key, "#{direction}\n#{PATH}\n#{stamp}\n#{raw}")
    "#{stamp}.#{digest}"
  end

  def response!(raw, header:, key:, now:, request:)
    match = /\A([0-9]{10})\.([0-9a-f]{64})\z/.match(header.to_s)
    raise Invalid unless raw.is_a?(String) && raw.bytesize <= MAX_BYTES && match && (now.to_i - match[1].to_i).abs <= 60

    expected = signature(raw, key: key, now: Time.at(match[1].to_i).utc, direction: 'RESPONSE').split('.').last
    raise Invalid unless OpenSSL.fixed_length_secure_compare(expected, match[2])

    validate_response!(JSON.parse(raw, allow_duplicate_key: false, max_nesting: 4), request)
  rescue JSON::ParserError
    raise Invalid
  end

  def validate_response!(value, request)
    raise Invalid unless value.is_a?(Hash) && value.keys.sort == %w[authority request_sha256 version] && value['version'] == 1 &&
                         value['request_sha256'] == Digest::SHA256.hexdigest(JSON.generate(request))

    receipt = value['authority']
    input = request.fetch('authority')
    validate_receipt!(receipt, input)
    value
  rescue KeyError, TypeError
    raise Invalid
  end

  def validate_receipt!(receipt, input)
    raise Invalid unless receipt.is_a?(Hash) && receipt.keys.sort == RESPONSE_FIELDS.sort &&
                         receipt.values_at('authorityId', 'organizationId', 'authorityHash', 'execute') ==
                         [input['authorityId'], input['organizationId'], Record.digest(input), false]
    raise Invalid unless %w[pending ready stale].include?(receipt['state']) && [true, false].include?(receipt['current']) &&
                         Record.hash?(receipt['pointerHash'])
  end
end
