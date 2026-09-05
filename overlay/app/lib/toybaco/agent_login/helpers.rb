# frozen_string_literal: true

require 'digest'
require 'json'
require 'openssl'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module AgentLogin
    module Helpers
      module_function

      def present_string(value)
        text = value.to_s
        text unless text.strip.empty? || text.match?(/[\r\n\0]/) || text.bytesize > 2048
      end

      def integer_id(value)
        return value if value.is_a?(Integer)
        return unless value.to_s.match?(/\A[1-9]\d{0,8}\z/)

        value.to_i
      end

      def decode_secret(raw)
        parsed = raw.is_a?(Hash) ? raw : JSON.parse(raw.to_s)
        parsed if parsed.is_a?(Hash)
      rescue JSON::ParserError, TypeError
        nil
      end

      def secret_identity(parsed)
        return [nil, nil, nil] unless parsed

        token = present_string(parsed['token'] || parsed[:token])
        email = present_string(parsed['email'] || parsed[:email]) || DEFAULT_EMAIL
        account_id = integer_id(parsed['account_id'] || parsed[:account_id]) || DEFAULT_ACCOUNT_ID
        [token, email, account_id]
      end

      def fixture_identity?(token, email, account_id)
        token && email == DEFAULT_EMAIL && account_id == DEFAULT_ACCOUNT_ID
      end

      def one_shot?(parsed)
        parsed['one_shot'] == true || parsed[:one_shot] == true
      end

      def signed_token_parts?(prefix, exp_raw, nonce, digest)
        prefix == SIGNED_PREFIX &&
          exp_raw.to_s.match?(/\A\d+\z/) &&
          nonce.to_s.match?(/\A[0-9a-f]{16,64}\z/) &&
          digest.to_s.match?(/\A[0-9a-f]{64}\z/)
      end

      def secure_match?(actual, expected)
        return false if actual.to_s.empty? || expected.to_s.empty?
        return false unless actual.bytesize == expected.bytesize

        if defined?(ActiveSupport::SecurityUtils)
          ActiveSupport::SecurityUtils.secure_compare(actual, expected)
        else
          OpenSSL.fixed_length_secure_compare(actual, expected)
        end
      end

      def valid_signed_token?(provided, hmac_key, now: Time.now.to_i)
        prefix, exp_raw, nonce, digest = provided.to_s.split('.', 4)
        return false unless signed_token_parts?(prefix, exp_raw, nonce, digest)

        exp = exp_raw.to_i
        return false if exp <= now || exp > now + SIGNED_TTL

        expected = OpenSSL::HMAC.hexdigest('SHA256', hmac_key, "#{SIGNED_PREFIX}|#{exp}|#{nonce}")
        secure_match?(digest, expected)
      end

      def consume!(token, store: default_store)
        return false unless store && present_string(token)

        key = "#{USED_PREFIX}#{Digest::SHA256.hexdigest(token)}"
        stored = store.set(key, '1', not_exists: true, expires_in: SIGNED_TTL)
        stored == true || stored == 'OK'
      end

      def load_secret(env: ENV, reader: nil)
        injected = env[SECRET_JSON_ENV].to_s
        return parse_secret(injected) unless injected.strip.empty?

        raw = (reader || method(:read_secrets_manager)).call(present_string(env[SECRET_ID_ENV]) || SECRET_ID)
        parse_secret(raw)
      end

      def read_secrets_manager(secret_id)
        SecretsManagerReader.get_secret_string(secret_id)
      end

      def default_store
        RedisStore if defined?(Redis::Alfred)
      end
    end
  end
end
