# frozen_string_literal: true

require_relative 'gmail_api'
require_relative 'gmail_mailbox'
require_relative '../connection_release'
require_relative '../entitlements'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    module Gmail
      CONFIG_KEY = 'toybaco_gmail'
      CALLBACK_PATH = '/toybaco/connections/gmail/callback'

      module_function

      def client_id
        GlobalConfigService.load('TOYBACO_GMAIL_CLIENT_ID', nil).to_s
      end

      def api
        GmailApi.new(client_id: client_id, client_secret: GlobalConfigService.load('TOYBACO_GMAIL_CLIENT_SECRET', nil).to_s,
                     redirect_uri: ENV.fetch('FRONTEND_URL') + CALLBACK_PATH)
      end

      def public_decision
        return { 'available' => false, 'reason' => 'application_unconfigured' } unless configured?

        ConnectionRelease.current.decision(provider: 'gmail_rest', application_id: client_id, scopes: GmailApi::SCOPES,
                                           implementation_revision: GmailApi::REVISION, qualification_required: true)
      end

      def allowed?(account)
        return false unless account.active?

        decision = public_decision
        return false if %w[disabled revoked].include?(decision['reason'])
        return true if decision['available']

        review_account?(account) && configured?
      end

      def configured?
        !client_id.empty? && !GlobalConfigService.load('TOYBACO_GMAIL_CLIENT_SECRET', nil).to_s.empty?
      end

      def review_account?(account)
        # Browser/account parameters cannot grant review-tenant access.
        review = InstallationConfig.find_by(name: 'TOYBACO_CONNECTION_REVIEW_ACCOUNTS')&.value
        ids = review.is_a?(Hash) ? review.dig(ENV.fetch('TOYBACO_DEPLOYMENT_ENVIRONMENT', nil), 'gmail_rest') : nil
        ids.is_a?(Array) && ids.include?(account.id)
      end

      def connected?(channel)
        channel.respond_to?(:provider_config) && channel.provider == 'google' &&
          channel.provider_config.is_a?(Hash) && channel.provider_config[CONFIG_KEY].is_a?(Hash)
      end

      def config(channel)
        channel.provider_config.fetch(CONFIG_KEY)
      end

      def encryptor
        key = Rails.application.key_generator.generate_key('toybaco-gmail-credentials-v1', 32)
        ActiveSupport::MessageEncryptor.new(key, cipher: 'aes-256-gcm', serializer: JSON)
      end

      def credentials(channel)
        encryptor.decrypt_and_verify(config(channel).fetch('credentials'), purpose: purpose(channel)) || raise(GmailApi::Error, 401)
      end

      def encode_credentials(channel, tokens)
        encryptor.encrypt_and_sign(tokens, purpose: purpose(channel))
      end

      def purpose(channel)
        "toybaco-gmail:#{channel.account_id}:#{channel.id}"
      end

      def access_token(channel)
        channel.with_lock do
          tokens = credentials(channel)
          return tokens.fetch('access_token') if tokens.fetch('expires_at').to_i > Time.now.to_i + 60

          refreshed = api.refresh(refresh_token: tokens.fetch('refresh_token'))
          tokens = tokens.merge(refreshed.slice('access_token', 'refresh_token'))
                         .merge('expires_at' => Time.now.to_i + refreshed.fetch('expires_in').to_i)
          update_config!(channel, config(channel).merge('credentials' => encode_credentials(channel, tokens)))
          tokens.fetch('access_token')
        end
      end

      def update_config!(channel, values)
        channel.update!(provider_config: (channel.provider_config || {}).merge(CONFIG_KEY => values))
      end

      def connect!(account:, tokens:, profile:)
        GmailMailbox.new(account: account, tokens: tokens, profile: profile).connect!
      end
    end
  end
end
