# frozen_string_literal: true

require 'digest'
require 'openssl'
require 'json'
require_relative '../postiz_origin'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    module RetentionProtocol
      HEADER = 'X-Toybaco-Retention-Signature'
      PATH = '/toybaco/internal/posting-retention'
      PURPOSE = 'toybaco-posting-retention-v1'
      MAX_BYTES = 65_536
      PAIRS = { 'https://post.toybaco.jp' => ['https://app.toybaco.jp', 'live'],
                'https://post.staging.toybaco.jp' => ['https://app.staging.toybaco.jp', 'test'] }.freeze
      FIELDS = %w[version request_sha256 organization_id transition_id policy_hash receipt_hash kept_posts held_posts].freeze
      class Invalid < StandardError; end
      module_function

      def configuration(environment)
        origin = PostizOrigin.fetch!(environment)
        pair = PAIRS[origin]
        secret = environment['TOYBACO_OIDC_CLIENT_SECRET'].to_s
        raise Invalid unless environment['TOYBACO_POSTING_RETENTION_ENABLED'] == 'true' && pair &&
                             pair == [environment['FRONTEND_URL'], environment['TOYBACO_STRIPE_MODE']] && secret.bytesize >= 32

        { origin: origin, issuer: pair.first, key: OpenSSL::HMAC.digest('SHA256', secret, PURPOSE) }
      rescue ArgumentError
        raise Invalid
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
        validate_response!(value, request)
        value
      rescue JSON::ParserError
        raise Invalid
      end

      def validate_response!(value, request)
        raise Invalid unless value.is_a?(Hash) && value.keys.sort == FIELDS.sort && value['version'] == 1 &&
                             bound_response?(value, request) && valid_counts?(value)
      end

      def bound_response?(value, request)
        value['request_sha256'] == Digest::SHA256.hexdigest(JSON.generate(request)) &&
          %w[organization_id transition_id policy_hash].all? { |name| value[name] == request[name] } &&
          value['receipt_hash'].is_a?(String) && value['receipt_hash'].match?(/\A[0-9a-f]{64}\z/)
      end

      def valid_counts?(value)
        %w[kept_posts held_posts].all? { |name| value[name].is_a?(Integer) && value[name].between?(0, 10_000) }
      end
    end
  end
end
