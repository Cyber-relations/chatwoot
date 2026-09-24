# frozen_string_literal: true

require 'openssl'
require_relative '../postiz_origin'
require_relative 'posting_preparation_response'

module Toybaco::Growth::PostingPreparationProtocol
  Invalid = Toybaco::Growth::PostingPreparationRecord::Invalid
  PATH = '/toybaco/internal/posting-preparation'
  PURPOSE = 'toybaco-posting-preparation-v2'
  HEADER = 'X-Toybaco-Preparation-Signature'
  MAX_BYTES = 65_536
  PAIRS = { 'https://post.toybaco.jp' => ['https://app.toybaco.jp', 'live'],
            'https://post.staging.toybaco.jp' => ['https://app.staging.toybaco.jp', 'test'] }.freeze

  module_function

  def configuration(environment)
    origin = Toybaco::PostizOrigin.fetch!(environment)
    pair = PAIRS[origin]
    secret = environment['TOYBACO_OIDC_CLIENT_SECRET'].to_s
    raise Invalid unless environment['TOYBACO_POSTING_RELEASE_ENABLED'] == 'true' && pair &&
                         pair == [environment['FRONTEND_URL'], environment['TOYBACO_STRIPE_MODE']] && secret.bytesize >= 32

    { origin: origin, issuer: pair.first, mode: pair.last, key: OpenSSL::HMAC.digest('SHA256', secret, PURPOSE) }
  rescue ArgumentError
    raise Invalid
  end

  def request(value, account_id, config:, now:)
    raise Invalid unless value.dig('binding', 'mode') == config.fetch(:mode)

    { 'version' => 2, 'issuer' => config.fetch(:issuer), 'audience' => config.fetch(:origin), 'mode' => config.fetch(:mode),
      'preparation' => Toybaco::Growth::PostingPreparationExport.request(value, account_id, now: now) }
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

    value = JSON.parse(raw, allow_duplicate_key: false, max_nesting: 4)
    Toybaco::Growth::PostingPreparationResponse.validate!(value, request, now: now)
  rescue JSON::ParserError
    raise Invalid
  end
end
