# frozen_string_literal: true

require 'digest'
require 'openssl'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    module Handoff
      class Invalid < StandardError; end
      class Forbidden < StandardError; end
      class Limited < StandardError; end
      class Unavailable < StandardError; end

      module Access
        UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
        SECRET = /\A[0-9a-f]{64}\z/
        PROVIDERS = { 'line' => 'Channel::Line', 'gmail' => 'Channel::Email', 'microsoft' => 'Channel::Email',
                      'email' => 'Channel::Email', 'website' => 'Channel::WebWidget' }.freeze
        PRIVATE_FIELDS = { token_digest: nil, encrypted_token: nil, encrypted_recipient: nil, claim_digest: nil,
                           verification_digest: nil, encrypted_verification: nil, verification_browser_digest: nil }.freeze

        module_function

        def enabled?
          GlobalConfigService.load('TOYBACO_CONNECTION_HANDOFF_ENABLED', false) == true
        end

        def administrator!(account, user)
          valid = Account.exists?(id: account.id, status: :active) && user&.confirmed? &&
                  account.account_users.find_by(user_id: user.id)&.administrator?
          raise Forbidden unless valid
        end

        def current!(record, now: Time.now.utc)
          raise Unavailable unless enabled?
          raise Forbidden unless %w[issued claimed].include?(record.state) && record.expires_at > now

          administrator!(record.account, User.find_by(id: record.creator_id))
          target!(record.account, record.provider, record.inbox_id)
        end

        def target!(account, provider, inbox_id)
          raise Invalid unless PROVIDERS.key?(provider)
          return unless inbox_id

          inbox = account.inboxes.find_by(id: inbox_id)
          raise Forbidden unless inbox && inbox.channel_type == PROVIDERS.fetch(provider)

          verify_mail_provider!(inbox, provider)
        end

        def verify_mail_provider!(inbox, provider)
          expected = { 'gmail' => 'google', 'microsoft' => 'microsoft' }[provider]
          raise Forbidden if expected && inbox.channel.provider != expected
        end

        def receipt!(record, nonce)
          if record.state == 'completed'
            raise Unavailable unless enabled?
            raise Forbidden unless record.expires_at > Time.now.utc

            administrator!(record.account, User.find_by(id: record.creator_id))
          else
            current!(record)
          end
          valid_state = %w[claimed completed].include?(record.state)
          valid_nonce = nonce.to_s.match?(SECRET) && equal?(record.claim_digest, digest(nonce))
          raise Forbidden unless valid_state && valid_nonce
        end

        def token!(record, token)
          raise Forbidden unless record.state == 'issued' && token.to_s.match?(SECRET) && equal?(record.token_digest, digest(token))
        end

        def claim!(record, nonce)
          current!(record)
          raise Forbidden unless record.state == 'claimed' && nonce.to_s.match?(SECRET) && equal?(record.claim_digest, digest(nonce))
        end

        def digest(value)
          Digest::SHA256.hexdigest(value)
        end

        def recipient_digest(email)
          OpenSSL::HMAC.hexdigest('SHA256', key, "recipient:#{email.to_s.strip.downcase}")
        end

        def code_digest(record, revision, code)
          OpenSSL::HMAC.hexdigest('SHA256', key, "code:#{record.public_id}:#{revision}:#{code}")
        end

        def equal?(left, right)
          left.is_a?(String) && right.is_a?(String) && left.bytesize == right.bytesize &&
            ActiveSupport::SecurityUtils.secure_compare(left, right)
        end

        def key
          Rails.application.key_generator.generate_key('toybaco-connection-handoff-v1', 32)
        end

        def encode(record, kind, value)
          encryptor.encrypt_and_sign(value, purpose: "handoff:#{record.public_id}:#{kind}")
        end

        def decode(record, kind, value)
          raise Forbidden unless value.is_a?(String)

          result = encryptor.decrypt_and_verify(value, purpose: "handoff:#{record.public_id}:#{kind}")
          raise Forbidden unless result.is_a?(String)

          result
        end

        def encryptor
          ActiveSupport::MessageEncryptor.new(key, cipher: 'aes-256-gcm', serializer: JSON)
        end
      end
    end
  end
end
