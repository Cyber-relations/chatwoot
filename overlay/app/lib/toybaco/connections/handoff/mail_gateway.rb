# frozen_string_literal: true

require_relative '../gmail'
require_relative '../microsoft'
require_relative 'access'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    module Handoff
      class MailGateway
        PROVIDERS = %w[gmail microsoft].freeze

        def initialize(provider)
          raise Invalid unless PROVIDERS.include?(provider)

          @provider = provider
        end

        def allowed?(account)
          implementation.allowed?(account) && registered_callback?
        end

        def binding
          Access.digest([@provider, implementation.client_id, revision, callback_url].to_json)
        end

        def authorization_url(state:, challenge:)
          authorization_api.authorization_url(state: state, challenge: challenge)
        end

        def exchange(code:, verifier:)
          tokens = authorization_api.exchange(code: code, verifier: verifier)
          profile = data_api.profile(access_token: tokens.fetch('access_token'))
          result = { tokens: tokens, profile: profile }
          result[:folder] = data_api.inbox(access_token: tokens.fetch('access_token')) if @provider == 'microsoft'
          result
        end

        def connect!(account:, payload:)
          implementation.connect!(account: account, **payload)
        end

        def enqueue(inbox)
          job = @provider == 'gmail' ? Toybaco::GmailFetchJob : Toybaco::MicrosoftFetchJob
          job.perform_later(inbox.channel_id)
        rescue ActiveJob::EnqueueError, Redis::BaseError, IOError
          false # Periodic mailbox sweeps recover admission failures without repeating authorization.
        end

        private

        def implementation
          @provider == 'gmail' ? Gmail : Microsoft
        end

        def registered_callback?
          config = InstallationConfig.find_by(name: 'TOYBACO_CONNECTION_HANDOFF_MAIL')&.value
          entry = config.is_a?(Hash) ? config.dig(ENV.fetch('TOYBACO_DEPLOYMENT_ENVIRONMENT', nil), @provider) : nil
          entry.is_a?(Hash) && entry['application_id'] == implementation.client_id && entry['callback_url'] == callback_url &&
            entry['implementation_revision'] == revision
        end

        def revision
          @provider == 'gmail' ? GmailApi::REVISION : MicrosoftApi::REVISION
        end

        def callback_url
          origin = ENV.fetch('FRONTEND_URL').delete_suffix('/')
          raise Unavailable unless %w[https://app.toybaco.jp https://app.staging.toybaco.jp].include?(origin)

          "#{origin}/toybaco/connections/help/oauth/#{@provider}/callback"
        end

        def authorization_api
          klass = @provider == 'gmail' ? GmailApi : MicrosoftAuthorizationApi
          key = @provider == 'gmail' ? 'TOYBACO_GMAIL_CLIENT_SECRET' : 'TOYBACO_MICROSOFT_CLIENT_SECRET'
          klass.new(client_id: implementation.client_id, client_secret: GlobalConfigService.load(key, nil).to_s, redirect_uri: callback_url)
        end

        def data_api
          @provider == 'gmail' ? authorization_api : Microsoft.api
        end
      end
    end
  end
end
