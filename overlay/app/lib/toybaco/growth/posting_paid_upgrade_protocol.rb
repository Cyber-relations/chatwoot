# frozen_string_literal: true

require_relative 'posting_preparation_protocol'
require_relative 'posting_authority_record'

module Toybaco::Growth::PostingPaidUpgradeProtocol
  Invalid = Toybaco::Growth::PostingPreparationRecord::Invalid
  Record = Toybaco::Growth::PostingPreparationRecord
  PATH = '/toybaco/internal/posting-paid-upgrade'
  PURPOSE = 'toybaco-posting-paid-upgrade-v1'
  HEADER = 'X-Toybaco-Paid-Upgrade-Signature'
  MAX_BYTES = 65_536
  RESPONSE_FIELDS = %w[operationId requestHash receiptHash rootManifestHash state authorityId authorityHash pointerHash current execute].freeze
  HANDOFF_FIELDS = %w[accountId organizationId operationId sourceAuthorityId sourceAuthorityHash expectedPointerHash journalHash
                      periodHash sourceCoverageHash targetCoverageHash sourceBindingHash targetBindingHash sourcePrincipalHash selectionHash
                      sourceRank targetRank sourcePostingLimit targetPostingLimit sourceScheduledLimit targetScheduledLimit expiresAt].freeze
  APPLICATION_FIELDS = %w[receiptHash contractAppliedHash targetPrincipalHash authorityId railsAuthorityHash].freeze

  module_function

  def configuration(environment)
    # Recover existing receipts with admission flags off; origin/mode/key checks remain mandatory.
    config = Toybaco::Growth::PostingPreparationProtocol.configuration(environment.merge('TOYBACO_POSTING_RELEASE_ENABLED' => 'true'))
    config.merge(key: OpenSSL::HMAC.digest('SHA256', environment.fetch('TOYBACO_OIDC_CLIENT_SECRET'), PURPOSE))
  end

  def request(handoff, operation:, config:, application: nil)
    raise Invalid unless %w[prepare apply confirm status withdraw].include?(operation)

    validate_handoff!(handoff)
    raise Invalid unless %w[apply confirm].include?(operation) == !application.nil?

    validate_application!(application) if application
    { 'version' => 1, 'issuer' => config.fetch(:issuer), 'audience' => config.fetch(:origin), 'mode' => config.fetch(:mode),
      'operation' => operation, 'handoff' => handoff.deep_dup, 'application' => application&.deep_dup }
  end

  def validate_application!(value)
    raise Invalid unless value.is_a?(Hash) && value.keys.sort == APPLICATION_FIELDS.sort && value.values.all? { |item| Record.hash?(item) }
  end

  def validate_handoff!(value)
    numbers = %w[accountId sourceRank targetRank sourcePostingLimit targetPostingLimit sourceScheduledLimit targetScheduledLimit expiresAt]
    hashes = HANDOFF_FIELDS - numbers - ['organizationId']
    raise Invalid unless value.is_a?(Hash) && value.keys.sort == HANDOFF_FIELDS.sort

    validate_identifiers!(value, hashes)
    raise Invalid unless numbers.all? { |key| positive?(value[key]) }

    validate_limits!(value)
  end

  def validate_identifiers!(value, hashes)
    raise Invalid unless hashes.all? { |key| Record.hash?(value[key]) } && Record.ids?([value['organizationId']])
  end

  def positive?(value)
    value.is_a?(Integer) && value.between?(1, 9_007_199_254_740_991)
  end

  def validate_limits!(value)
    raise Invalid unless value['sourceRank'] < value['targetRank'] && value['targetRank'] <= 3
    raise Invalid unless %w[PostingLimit ScheduledLimit].all? do |suffix|
      value["target#{suffix}"].between?(value["source#{suffix}"], 10_000)
    end
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
    raise Invalid unless value.is_a?(Hash) && value.keys.sort == %w[handoff request_sha256 version] && value['version'] == 1 &&
                         value['request_sha256'] == Digest::SHA256.hexdigest(JSON.generate(request))

    receipt = value['handoff']
    validate_receipt!(receipt, request.fetch('handoff'))
    validate_response_authority!(receipt, request['application'])
    value
  rescue KeyError, TypeError
    raise Invalid
  end

  def validate_receipt!(receipt, input)
    raise Invalid unless receipt.is_a?(Hash) && receipt.keys.sort == RESPONSE_FIELDS.sort
    raise Invalid unless receipt.values_at('operationId', 'requestHash', 'execute') == [input['operationId'], Record.digest(input), false] &&
                         %w[pending applied ready withdrawn].include?(receipt['state']) && [true, false].include?(receipt['current'])

    validate_receipt_hashes!(receipt)
  end

  def validate_receipt_hashes!(receipt)
    raise Invalid unless %w[receiptHash rootManifestHash pointerHash].all? { |key| Record.hash?(receipt[key]) }
  end

  def validate_response_authority!(receipt, application)
    if %w[applied ready].include?(receipt['state'])
      raise Invalid unless %w[authorityId authorityHash].all? { |key| Record.hash?(receipt[key]) }
      raise Invalid if application && receipt['authorityId'] != application['authorityId']
    else
      raise Invalid unless receipt.values_at('authorityId', 'authorityHash', 'current') == [nil, nil, false]
    end
  end
end
