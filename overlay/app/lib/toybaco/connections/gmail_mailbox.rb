# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    class GmailMailbox
      def initialize(account:, tokens:, profile:)
        @account = account
        @tokens = tokens
        @email = profile.fetch('emailAddress').to_s.downcase
        @history_id = profile.fetch('historyId').to_s
      end

      def connect!
        validate_profile!
        @account.with_lock do
          channel = existing_channel || create_channel!
          channel.with_lock { configure!(channel) }
          channel.inbox
        end
      end

      private

      def validate_profile!
        raise GmailApi::Error, 502 unless @email.match?(/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/) && @history_id.match?(/\A\d+\z/)
        raise GmailApi::Error.new(403, nil, 'insufficient_scope') if @tokens['refresh_token'].to_s.empty?
      end

      def existing_channel
        @account.email_channels.where('LOWER(email) = :email OR LOWER(imap_login) = :email', email: @email).first
      end

      def create_channel!
        limit = Toybaco::Entitlements.for_account(@account)&.dig('limits', 'inboxes')
        raise GmailApi::Error, 409 if limit && @account.inboxes.count >= limit

        channel = Channel::Email.create!(email: @email, account: @account)
        @account.inboxes.create!(account: @account, channel: channel, name: @email)
        channel
      end

      def configure!(channel)
        # Preserve the original inbox and cursor during explicit reauthorization.
        # A new revision fences workers holding the previous authorization.
        previous = Gmail.connected?(channel) ? Gmail.config(channel) : {}
        tokens = @tokens.slice('access_token', 'refresh_token').merge('expires_at' => Time.now.to_i + @tokens.fetch('expires_in').to_i)
        values = previous.merge('credentials' => Gmail.encode_credentials(channel, tokens),
                                'connected_at' => previous['connected_at'] || Time.now.utc.iso8601, 'connection_revision' => SecureRandom.hex(16))
        values['sync'] ||= { 'history_id' => @history_id, 'last_synced_at' => Time.now.utc.iso8601 }
        channel.update!(provider: 'google', imap_enabled: false, smtp_enabled: false, imap_password: '', smtp_password: '',
                        provider_config: { Gmail::CONFIG_KEY => values }, verified_for_sending: true)
        channel.reauthorized!
      end
    end
  end
end
