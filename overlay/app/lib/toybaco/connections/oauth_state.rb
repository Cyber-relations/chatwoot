# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'digest'
require 'base64'
require 'openssl'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    # Unlike an account signed ID, a nonce is one-use, user-bound and browser-
    # bound. No return URL, account ID or provider from the callback is trusted.
    class OauthState
      PREFIX = 'TOYBACO_CONNECTION_STATE::'
      TTL = 15 * 60
      RETURNS = %w[onboarding settings growth].freeze

      def initialize(store:, now: Time.now.utc)
        @store = store
        @now = now
      end

      def issue(account_id:, user_id:, browser_nonce:, provider:, return_to:)
        ids_valid = positive_id?(account_id) && positive_id?(user_id)
        context_valid = browser_nonce.to_s.match?(/\A[0-9a-f]{64}\z/) && provider.to_s.match?(/\A[a-z][a-z0-9_]*\z/) && RETURNS.include?(return_to)
        raise ArgumentError, 'invalid OAuth binding' unless ids_valid && context_valid

        state = SecureRandom.hex(32)
        verifier = SecureRandom.urlsafe_base64(48)
        payload = {
          'account_id' => account_id.to_i, 'user_id' => user_id.to_i,
          'browser_digest' => Digest::SHA256.hexdigest(browser_nonce), 'provider' => provider,
          'return_to' => return_to, 'verifier' => verifier, 'expires_at' => @now.to_i + TTL
        }
        stored = @store.set(PREFIX + state, JSON.generate(payload), nx: true, ex: TTL)
        raise IOError, 'connection state unavailable' unless stored

        { 'state' => state, 'challenge' => Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false) }
      end

      def consume(state, user_id:, browser_nonce:, provider:)
        return unless state.to_s.match?(/\A[0-9a-f]{64}\z/) && browser_nonce.to_s.match?(/\A[0-9a-f]{64}\z/)

        key = PREFIX + state
        value = @store.get(key)
        return unless value

        payload = JSON.parse(value)
        return unless valid_payload?(payload, user_id, browser_nonce, provider)
        # Match the namespaced Redis adapter's compare-and-delete semantics.
        # A truthy "OK" from a failed WATCH transaction is not consumption.
        return unless Array(@store.delete_if_equals(key, value)).first == 1

        payload
      rescue JSON::ParserError, TypeError
        nil
      end

      private

      def positive_id?(value)
        value.to_s.match?(/\A[1-9]\d*\z/)
      end

      def valid_payload?(payload, user_id, browser_nonce, provider)
        payload.is_a?(Hash) && positive_id?(payload['account_id']) && positive_id?(user_id) &&
          payload['user_id'] == user_id.to_i && payload['provider'] == provider && usable_payload?(payload) &&
          secure_equal?(payload['browser_digest'], Digest::SHA256.hexdigest(browser_nonce))
      end

      def usable_payload?(payload)
        payload['expires_at'].is_a?(Integer) && payload['expires_at'] > @now.to_i &&
          RETURNS.include?(payload['return_to']) && payload['verifier'].to_s.match?(/\A[A-Za-z0-9_-]{43,128}\z/)
      end

      def secure_equal?(left, right)
        return false unless left.is_a?(String) && left.bytesize == right.bytesize
        return OpenSSL.fixed_length_secure_compare(left, right) if OpenSSL.respond_to?(:fixed_length_secure_compare)

        # macOS's older system Ruby also runs the repository's standalone checks.
        left.bytes.zip(right.bytes).reduce(0) { |difference, pair| difference | (pair[0] ^ pair[1]) }.zero?
      end
    end
  end
end
