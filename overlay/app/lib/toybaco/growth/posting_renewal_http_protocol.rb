# frozen_string_literal: true

require_relative 'posting_preparation_protocol'

module Toybaco::Growth::PostingRenewalHttpProtocol
  Record = Toybaco::Growth::PostingPreparationRecord
  Invalid = Record::Invalid
  PATH = '/toybaco/internal/posting-renewal'
  PURPOSE = 'toybaco-posting-renewal-v1'
  HEADER = 'X-Toybaco-Renewal-Signature'
  MAX_BYTES = 65_536

  module_function

  def configuration(environment)
    origin = Toybaco::PostizOrigin.fetch!(environment)
    pair = Toybaco::Growth::PostingPreparationProtocol::PAIRS[origin]
    secret = environment['TOYBACO_OIDC_CLIENT_SECRET'].to_s
    raise Invalid unless pair == [environment['FRONTEND_URL'], environment['TOYBACO_STRIPE_MODE']] && secret.bytesize >= 32

    { origin: origin, issuer: pair.first, mode: pair.last, key: OpenSSL::HMAC.digest('SHA256', secret, PURPOSE) }
  rescue ArgumentError
    raise Invalid
  end

  def request(input, config:)
    { 'version' => 1, 'issuer' => config.fetch(:issuer), 'audience' => config.fetch(:origin),
      'mode' => config.fetch(:mode), 'renewal' => input.deep_dup }
  end

  def signature(raw, key:, now:, direction:)
    stamp = now.to_i.to_s
    "#{stamp}.#{OpenSSL::HMAC.hexdigest('SHA256', key, "#{direction}\n#{PATH}\n#{stamp}\n#{raw}")}"
  end

  def response!(raw, header:, key:, now:, request:)
    verify_signature!(raw, header, key, now)
    value = response_body!(raw, request)
    Toybaco::Growth::PostingRenewalProtocol.validate_receipt!(value.fetch('renewal'), request.fetch('renewal'))
    value
  rescue JSON::ParserError, KeyError, TypeError
    raise Invalid
  end

  def verify_signature!(raw, header, key, now)
    match = /\A([0-9]{10})\.([0-9a-f]{64})\z/.match(header.to_s)
    raise Invalid unless raw.is_a?(String) && raw.bytesize <= MAX_BYTES && match && (now.to_i - match[1].to_i).abs <= 60

    expected = signature(raw, key: key, now: Time.at(match[1].to_i).utc, direction: 'RESPONSE').split('.').last
    raise Invalid unless OpenSSL.fixed_length_secure_compare(expected, match[2])
  end

  def response_body!(raw, request)
    value = JSON.parse(raw, allow_duplicate_key: false, max_nesting: 4)
    raise Invalid unless JSON.generate(value) == raw && value.keys.sort == %w[renewal request_sha256 version] && value['version'] == 1 &&
                         value['request_sha256'] == Digest::SHA256.hexdigest(JSON.generate(request))

    value
  end
end
