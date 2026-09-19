# frozen_string_literal: true

require 'openssl'
require 'json'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    module PaymentSignature
      MAX_BYTES = 262_144
      class Invalid < StandardError; end
      class Unconfigured < StandardError; end

      module_function

      def configured?(environment = ENV)
        environment['TOYBACO_STRIPE_PACK_WEBHOOK_SECRET'].to_s.match?(/\Awhsec_[A-Za-z0-9]{16,}\z/)
      end

      def verify!(raw, signature, environment: ENV, now: Time.now.utc)
        secret = secret!(raw, signature, environment)
        fields = signature.to_s.split(',').map { |part| part.split('=', 2) }
        stamp = timestamp(fields, now)
        expected = OpenSSL::HMAC.hexdigest('SHA256', secret, "#{stamp}.#{raw}")
        raise Invalid unless signed?(fields, expected)

        JSON.parse(raw, allow_duplicate_key: false, max_nesting: 32)
      rescue JSON::ParserError
        raise Invalid
      end

      def secret!(raw, signature, environment)
        secret = environment['TOYBACO_STRIPE_PACK_WEBHOOK_SECRET'].to_s
        raise Unconfigured unless configured?(environment)
        raise Invalid unless raw.is_a?(String) && raw.bytesize <= MAX_BYTES && signature.to_s.bytesize <= 4096

        secret
      end

      def signed?(fields, expected)
        fields.any? { |key, value| key == 'v1' && value.to_s.match?(/\A[0-9a-f]{64}\z/) && secure_equal(expected, value) }
      end

      def timestamp(fields, now)
        stamps = fields.filter_map { |key, value| value if key == 't' }
        valid = stamps.length == 1 && stamps.first.to_s.match?(/\A[0-9]{10}\z/) && (now.to_i - stamps.first.to_i).abs <= 300
        raise Invalid unless valid

        stamps.first
      end

      def secure_equal(expected, received)
        OpenSSL.fixed_length_secure_compare(expected, received)
      end
    end
  end
end
