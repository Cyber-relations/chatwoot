# frozen_string_literal: true

require 'openssl'
require_relative '../connections/gmail'
require_relative '../connections/microsoft'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class TrialConnection
      def self.identity(inbox)
        return unless ready?(inbox)

        provider, external_id = external_identity(inbox.channel)
        return unless external_id

        key = Rails.application.key_generator.generate_key('toybaco-trial-identity-v1', 32)
        { provider: provider, identity_digest: OpenSSL::HMAC.hexdigest('SHA256', key, external_id) }
      end

      def self.external_identity(channel)
        return ['microsoft', Connections::Microsoft.config(channel)['subject_id']] if Connections::Microsoft.connected?(channel)

        ['gmail', normalized_email(channel.email)]
      end

      def self.ready?(inbox)
        channel = inbox.channel
        return false unless channel.respond_to?(:reauthorization_required?)
        return false if channel.reauthorization_required? || !inbox.agent_bot_inbox&.active?

        return Connections::Gmail.allowed?(inbox.account) if Connections::Gmail.connected?(channel)

        Connections::Microsoft.application_current?(channel) && Connections::Microsoft.allowed?(inbox.account)
      end

      def self.normalized_email(value)
        email = value.to_s.downcase
        local, domain = email.split('@', 2)
        return unless local.present? && domain.present?

        email = "#{local.split('+').first.delete('.')}@gmail.com" if %w[gmail.com googlemail.com].include?(domain)
        email
      end

      def self.allowed?(account, inbox)
        trial = Toybaco::GrowthTrial.find_by(account_id: account.id)
        identity = self.identity(inbox)
        trial && !trial.completed_at && trial.ends_at > Time.now.utc && identity && trial.identities.exists?(identity)
      end
    end
  end
end
