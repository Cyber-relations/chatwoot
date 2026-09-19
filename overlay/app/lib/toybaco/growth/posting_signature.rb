# frozen_string_literal: true

require 'openssl'
require 'json'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    module PostingSignature
      PATH = '/toybaco/internal/post-drafts'
      PURPOSE = 'toybaco-posting-ai-v1'
      MAX_BYTES = 32_768
      class Invalid < StandardError; end
      class Unconfigured < StandardError; end
      module_function

      def verify!(raw, signature, environment: ENV, now: Time.now.utc)
        key = signing_key(environment)
        raise Invalid unless raw.is_a?(String) && raw.bytesize <= MAX_BYTES

        match = signature_parts(signature, now)

        expected = OpenSSL::HMAC.hexdigest('SHA256', key, "POST\n#{PATH}\n#{match[1]}\n#{raw}")
        raise Invalid unless OpenSSL.fixed_length_secure_compare(expected, match[2])

        payload = JSON.parse(raw, allow_duplicate_key: false, max_nesting: 8)
        raise Invalid unless payload.is_a?(Hash) && payload['audience'] == environment['FRONTEND_URL']

        payload
      rescue JSON::ParserError
        raise Invalid
      end

      def signature_parts(signature, now)
        match = /\A([0-9]{10})\.([0-9a-f]{64})\z/.match(signature.to_s)
        raise Invalid unless match && (now.to_i - match[1].to_i).abs <= 60

        match
      end

      def signing_key(environment)
        secret = environment['TOYBACO_OIDC_CLIENT_SECRET'].to_s
        raise Unconfigured unless secret.bytesize >= 32 && environment['FRONTEND_URL'].to_s.start_with?('http://', 'https://')

        OpenSSL::HMAC.digest('SHA256', secret, PURPOSE)
      end
    end
  end
end
