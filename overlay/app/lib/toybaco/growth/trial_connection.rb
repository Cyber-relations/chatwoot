# frozen_string_literal: true

require 'openssl'
require_relative '../connections/gmail'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class TrialConnection
      def self.identity(inbox)
        return unless ready?(inbox)

        email = normalized_email(inbox.channel.email)
        return unless email

        key = Rails.application.key_generator.generate_key('toybaco-trial-identity-v1', 32)
        { provider: 'gmail', identity_digest: OpenSSL::HMAC.hexdigest('SHA256', key, email) }
      end

      def self.ready?(inbox)
        channel = inbox.channel
        Connections::Gmail.connected?(channel) && Connections::Gmail.allowed?(inbox.account) &&
          !channel.reauthorization_required? && inbox.agent_bot_inbox&.active?
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
