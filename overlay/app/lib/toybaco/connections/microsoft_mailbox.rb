# frozen_string_literal: true

require_relative 'microsoft_api'
require_relative 'inbox_limit'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    class MicrosoftMailbox
      # 契約の受信箱上限。再試行では解消しないため、呼び出し側が上限と現在の件数を案内できるよう区別する。
      class LimitReached < MicrosoftApi::Error
        attr_reader :limit, :count

        def initialize(limit, count)
          @limit = limit
          @count = count
          super(409, nil, 'inbox_limit')
        end
      end

      def initialize(account:, tokens:, profile:, folder:)
        @account = account
        @tokens = tokens
        @email = (profile['mail'].presence || profile['userPrincipalName']).to_s.downcase
        @subject = profile.fetch('id').to_s
        @folder = folder.fetch('id').to_s
      end

      def connect!
        validate_profile!
        @account.with_lock do
          raise MicrosoftApi::Error, 403 unless @account.active?

          channel = existing_channel || create_channel!
          channel.with_lock { configure!(channel) }
          channel.inbox
        end
      end

      private

      def validate_profile!
        raise MicrosoftApi::Error, 502 unless @email.bytesize <= 320 && @email.match?(URI::MailTo::EMAIL_REGEXP)
        raise MicrosoftApi::Error, 502 unless [@subject, @folder].all? { |id| id.match?(%r{\A[A-Za-z0-9_=+/-]{1,2048}\z}) }
        raise MicrosoftApi::Error.new(403, nil, 'insufficient_scope') if @tokens['refresh_token'].to_s.empty?
      end

      def existing_channel
        channel = identity_channel || @account.email_channels.where('LOWER(email) = :email OR LOWER(imap_login) = :email', email: @email).first
        return unless channel
        raise MicrosoftApi::Error, 409 if channel.provider.present? && channel.provider != 'microsoft'
        raise MicrosoftApi::Error, 409 if Microsoft.connected?(channel) && Microsoft.config(channel)['subject_id'] != @subject

        channel
      end

      def identity_channel
        channel = Channel::Email.where(provider: 'microsoft').where("provider_config->'toybaco_microsoft'->>'subject_id' = ?", @subject).first
        raise MicrosoftApi::Error, 409 if channel && channel.account_id != @account.id

        channel
      end

      def create_channel!
        reached = InboxLimit.reached(@account)
        raise LimitReached.new(*reached) if reached

        channel = Channel::Email.create!(email: @email, account: @account)
        @account.inboxes.create!(account: @account, channel: channel, name: @email)
        channel
      end

      def configure!(channel)
        previous = Microsoft.connected?(channel) ? Microsoft.config(channel) : {}
        tokens = @tokens.slice('access_token', 'refresh_token').merge('expires_at' => Time.now.to_i + @tokens.fetch('expires_in').to_i)
        values = previous.merge('credentials' => Microsoft.encode_credentials(channel, tokens), 'subject_id' => @subject,
                                'connected_at' => previous['connected_at'] || Time.now.utc.iso8601, 'connection_revision' => SecureRandom.hex(16),
                                'application_id' => Microsoft.client_id, 'implementation_revision' => MicrosoftApi::REVISION)
        values['sync'] = { 'folder_id' => @folder } unless values.dig('sync', 'folder_id') == @folder
        channel.update!(email: @email, provider: 'microsoft', imap_enabled: false, smtp_enabled: false, imap_password: '', smtp_password: '',
                        provider_config: { Microsoft::CONFIG_KEY => values }, verified_for_sending: true)
        channel.reauthorized!
      end
    end
  end
end
