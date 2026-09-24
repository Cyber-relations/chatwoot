# frozen_string_literal: true

require 'openssl'
require_relative 'posting_authority_record'
require_relative '../postiz_origin'

module Toybaco::Growth::PostingExecutionProtocol
  Record = Toybaco::Growth::PostingPreparationRecord
  Invalid = Record::Invalid
  PATH = '/toybaco/internal/posting-execution'
  PURPOSE = 'toybaco-posting-execution-v3'
  HEADER = 'X-Toybaco-Execution-Signature'
  MAX_BYTES = 65_536
  ENVELOPE = %w[version issuer audience mode operation execution].freeze
  FIELDS = %w[authorityId authorityHash railsAuthorityHash accountId organizationId ownerId actorId rootId stepPostId step
              rootGeneration markerHash saveRequestId scheduleHash reservationHash sequence previousPendingHash pendingDataHash].freeze
  IDENTITY = %w[organizationId rootId rootGeneration step stepPostId sequence].freeze
  HASH_FIELDS = %w[authorityId authorityHash railsAuthorityHash markerHash scheduleHash reservationHash].freeze
  ID = /\A[A-Za-z0-9_-]{1,128}\z/
  UUID = '[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}'
  UUID_PATTERN = /\A#{UUID}\z/
  GENERATION = /\A[0-9]{13}:#{UUID}\z/

  module_function

  def configuration(environment)
    origin = Toybaco::PostizOrigin.fetch!(environment)
    pair = Toybaco::Growth::PostingPreparationProtocol::PAIRS[origin]
    secret = environment['TOYBACO_OIDC_CLIENT_SECRET'].to_s
    raise Invalid unless pair == [environment['FRONTEND_URL'], environment['TOYBACO_STRIPE_MODE']] && pair && secret.bytesize >= 32

    { origin: origin, issuer: pair.first, mode: pair.last, key: OpenSSL::HMAC.digest('SHA256', secret, PURPOSE) }
  rescue ArgumentError
    raise Invalid
  end

  def signature(raw, key:, now:, direction:)
    stamp = now.to_i.to_s
    digest = OpenSSL::HMAC.hexdigest('SHA256', key, "#{direction}\n#{PATH}\n#{stamp}\n#{raw}")
    "#{stamp}.#{digest}"
  end

  def request!(raw, header:, config:, now:)
    match = /\A([0-9]{10})\.([0-9a-f]{64})\z/.match(header.to_s)
    raise Invalid unless raw.is_a?(String) && raw.bytesize <= MAX_BYTES && match && (now.to_i - match[1].to_i).abs <= 60

    expected = signature(raw, key: config.fetch(:key), now: Time.at(match[1].to_i).utc, direction: 'POST').split('.').last
    raise Invalid unless OpenSSL.fixed_length_secure_compare(expected, match[2])

    validate_envelope!(JSON.parse(raw, allow_duplicate_key: false, max_nesting: 4), config)
  rescue JSON::ParserError
    raise Invalid
  end

  def validate_envelope!(value, config)
    raise Invalid unless value.is_a?(Hash) && %w[start status result].include?(value['operation'])

    keys = value['operation'] == 'result' ? ENVELOPE + %w[outcome evidenceHash] : ENVELOPE
    raise Invalid unless value.keys.sort == keys.sort && value.values_at('version', 'issuer', 'audience', 'mode') ==
                                                         [3, config.fetch(:origin), config.fetch(:issuer), config.fetch(:mode)]

    validate_result!(value) if value['operation'] == 'result'
    validate_execution!(value['execution'])
    value
  end

  def validate_result!(value)
    raise Invalid unless %w[pending published rejected not_sent uncertain].include?(value['outcome']) && Record.hash?(value['evidenceHash'])
  end

  def validate_execution!(value)
    raise Invalid unless value.is_a?(Hash) && value.keys.sort == FIELDS.sort
    raise Invalid unless HASH_FIELDS.all? { |key| Record.hash?(value[key]) }

    validate_identity!(value)
    validate_step!(value)
    value
  end

  def validate_identity!(value)
    raise Invalid unless %w[accountId ownerId actorId].all? { |key| value[key].is_a?(Integer) && value[key].between?(1, 9_007_199_254_740_991) }
    raise Invalid unless %w[organizationId rootId stepPostId].all? { |key| value[key].is_a?(String) && ID.match?(value[key]) }
  end

  def validate_step!(value)
    raise Invalid unless value['saveRequestId'].is_a?(String) && UUID_PATTERN.match?(value['saveRequestId']) &&
                         value['rootGeneration'].is_a?(String) && GENERATION.match?(value['rootGeneration'])
    raise Invalid unless %w[MAIN COMMENT FINALIZE].include?(value['step'])

    validate_root!(value)
    validate_sequence!(value)
  end

  def validate_sequence!(value)
    raise Invalid unless value['sequence'].is_a?(Integer)
    return validate_final_sequence!(value) if value['step'] == 'FINALIZE'

    raise Invalid unless value['sequence'].zero? && value['previousPendingHash'].nil? && value['pendingDataHash'].nil?
  end

  def validate_final_sequence!(value)
    raise Invalid unless value['sequence'].between?(1, 10_000) &&
                         Record.hash?(value['previousPendingHash']) && Record.hash?(value['pendingDataHash'])
  end

  def validate_root!(value)
    raise Invalid unless value['step'] == 'COMMENT' || value['rootId'] == value['stepPostId']
  end

  def operation_id(value)
    Record.digest(value.slice(*IDENTITY))
  end

  def response(raw_request, receipt)
    { 'version' => 3, 'request_sha256' => Digest::SHA256.hexdigest(raw_request), 'execution' => receipt }
  end
end
