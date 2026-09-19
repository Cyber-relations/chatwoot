# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'digest'
require 'base64'
require 'openssl'
require_relative 'access'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    module Handoff
      # One active authorization per handoff; it never creates store membership.
      class MailOauthState
        PREFIX = 'TOYBACO_HANDOFF_MAIL_STATE::'
        TTL = 15 * 60
        FIELDS = %w[application browser_digest expires_at provider public_id state_digest verifier].freeze
        PROVIDERS = %w[gmail microsoft].freeze

        def initialize(store:, now: Time.now.utc)
          @store = store
          @now = now
        end

        def issue(public_id:, provider:, browser_nonce:, application:, expires_at:)
          validate_binding!(public_id, provider, browser_nonce, application)
          ttl = [TTL, expires_at.to_i - @now.to_i].min
          raise Forbidden unless ttl.positive?
          raise Limited unless @store.set("#{PREFIX}RATE::#{public_id}", '1', nx: true, ex: 10)

          state = SecureRandom.hex(32)
          verifier = SecureRandom.urlsafe_base64(48)
          payload = { 'public_id' => public_id, 'provider' => provider, 'browser_digest' => Digest::SHA256.hexdigest(browser_nonce),
                      'application' => application, 'state_digest' => Digest::SHA256.hexdigest(state), 'verifier' => verifier,
                      'expires_at' => @now.to_i + ttl }
          raise Unavailable unless @store.set(PREFIX + public_id, JSON.generate(payload), ex: ttl)

          { 'state' => state, 'challenge' => Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false) }
        end

        def consume(state, public_id:, provider:, browser_nonce:, application:)
          validate_binding!(public_id, provider, browser_nonce, application)
          return unless state.is_a?(String) && state.match?(Access::SECRET)

          key = PREFIX + public_id
          value = @store.get(key)
          payload = parse_payload(value)
          return unless valid_payload?(payload, public_id, provider, application) && bound_secrets?(payload, state, browser_nonce)
          return unless Array(@store.delete_if_equals(key, value)).first == 1

          payload
        rescue JSON::ParserError, TypeError
          nil
        end

        private

        def parse_payload(value)
          return unless value.is_a?(String) && value.bytesize <= 8192

          JSON.parse(value, max_nesting: 4, allow_duplicate_key: false)
        end

        def validate_binding!(public_id, provider, nonce, application)
          valid = public_id.is_a?(String) && public_id.match?(Access::UUID) && PROVIDERS.include?(provider) &&
                  [nonce, application].all? { |value| value.is_a?(String) && value.match?(Access::SECRET) }
          raise Forbidden unless valid
        end

        def valid_payload?(payload, public_id, provider, application)
          payload.is_a?(Hash) && payload.keys.sort == FIELDS && valid_identity?(payload, public_id, provider, application) &&
            valid_expiry?(payload['expires_at']) && valid_verifier?(payload['verifier'])
        end

        def valid_identity?(payload, public_id, provider, application)
          payload['public_id'] == public_id && payload['provider'] == provider && equal?(payload['application'], application)
        end

        def valid_verifier?(verifier)
          verifier.is_a?(String) && verifier.match?(/\A[A-Za-z0-9_-]{43,128}\z/)
        end

        def bound_secrets?(payload, state, nonce)
          equal?(payload['state_digest'], Digest::SHA256.hexdigest(state)) && equal?(payload['browser_digest'], Digest::SHA256.hexdigest(nonce))
        end

        def valid_expiry?(expires_at)
          expires_at.is_a?(Integer) && expires_at > @now.to_i && expires_at <= @now.to_i + TTL
        end

        def equal?(left, right)
          left.is_a?(String) && left.bytesize == right.bytesize && OpenSSL.fixed_length_secure_compare(left, right)
        end
      end
    end
  end
end
