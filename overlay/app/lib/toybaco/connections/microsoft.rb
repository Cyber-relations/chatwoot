# frozen_string_literal: true

require_relative 'microsoft_api'
require_relative 'microsoft_draft_api'
require_relative 'microsoft_mailbox'
require_relative '../connection_release'
require_relative '../entitlements'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    module Microsoft
      CONFIG_KEY = 'toybaco_microsoft'
      CALLBACK_PATH = '/toybaco/connections/microsoft/callback'

      module_function

      def client_id
        GlobalConfigService.load('TOYBACO_MICROSOFT_CLIENT_ID', nil).to_s
      end

      def api
        MicrosoftDraftApi.new
      end

      def authorization_api
        MicrosoftAuthorizationApi.new(client_id: client_id, client_secret: GlobalConfigService.load('TOYBACO_MICROSOFT_CLIENT_SECRET', nil).to_s,
                                      redirect_uri: ENV.fetch('FRONTEND_URL') + CALLBACK_PATH)
      end

      def public_decision
        return { 'available' => false, 'reason' => 'application_unconfigured' } unless configured?

        ConnectionRelease.current.decision(provider: 'microsoft_graph', application_id: client_id, scopes: MicrosoftApi::SCOPES,
                                           implementation_revision: MicrosoftApi::REVISION, qualification_required: true)
      end

      def allowed?(account)
        return false unless account.active?

        decision = public_decision
        return false if %w[disabled revoked].include?(decision['reason'])
        return true if decision['available']

        review_account?(account) && configured?
      end

      def configured?
        !client_id.empty? && !GlobalConfigService.load('TOYBACO_MICROSOFT_CLIENT_SECRET', nil).to_s.empty?
      end

      def review_account?(account)
        # Browser/account parameters cannot grant review-tenant access.
        review = InstallationConfig.find_by(name: 'TOYBACO_CONNECTION_REVIEW_ACCOUNTS')&.value
        ids = review.is_a?(Hash) ? review.dig(ENV.fetch('TOYBACO_DEPLOYMENT_ENVIRONMENT', nil), 'microsoft_graph') : nil
        ids.is_a?(Array) && ids.include?(account.id)
      end

      def connected?(channel)
        channel.respond_to?(:provider_config) && channel.provider == 'microsoft' &&
          channel.provider_config.is_a?(Hash) && channel.provider_config[CONFIG_KEY].is_a?(Hash)
      end

      def config(channel)
        channel.provider_config.fetch(CONFIG_KEY)
      end

      def application_current?(channel)
        connected?(channel) && config(channel)['application_id'] == client_id && config(channel)['implementation_revision'] == MicrosoftApi::REVISION
      end

      def encryptor
        key = Rails.application.key_generator.generate_key('toybaco-microsoft-credentials-v1', 32)
        ActiveSupport::MessageEncryptor.new(key, cipher: 'aes-256-gcm', serializer: JSON)
      end

      def credentials(channel)
        encryptor.decrypt_and_verify(config(channel).fetch('credentials'), purpose: purpose(channel)) || raise(MicrosoftApi::Error, 401)
      end

      def encode_credentials(channel, tokens)
        encryptor.encrypt_and_sign(tokens, purpose: purpose(channel))
      end

      def purpose(channel)
        "toybaco-microsoft:#{channel.account_id}:#{channel.id}"
      end

      def access_token(channel)
        channel.with_lock do
          raise MicrosoftApi::Error, 401 unless application_current?(channel)

          tokens = credentials(channel)
          return tokens.fetch('access_token') if tokens.fetch('expires_at').to_i > Time.now.to_i + 60

          refresh_credentials(channel, tokens)
        end
      end

      def refresh_credentials(channel, tokens)
        refreshed = authorization_api.refresh(refresh_token: tokens.fetch('refresh_token'))
        tokens = tokens.merge(refreshed.slice('access_token', 'refresh_token').compact)
                       .merge('expires_at' => Time.now.to_i + refreshed.fetch('expires_in').to_i)
        update_config!(channel, config(channel).merge('credentials' => encode_credentials(channel, tokens)))
        tokens.fetch('access_token')
      end

      def update_config!(channel, values)
        channel.update!(provider_config: (channel.provider_config || {}).merge(CONFIG_KEY => values))
      end

      def connect!(account:, tokens:, profile:, folder:)
        MicrosoftMailbox.new(account: account, tokens: tokens, profile: profile, folder: folder).connect!
      end
    end
  end
end
