# frozen_string_literal: true

require_relative 'access'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    module Handoff
      class MailTarget
        def initialize(record)
          @record = record
        end

        def verify!(profile)
          raise Invalid unless profile.is_a?(Hash)

          candidates = matching_channels(profile)
          raise Forbidden if candidates.any? { |channel| channel.inbox.nil? }

          expected = @record.inbox_id ? [@record.inbox_id] : []
          raise Forbidden unless candidates.map { |channel| channel.inbox.id }.sort == expected
        end

        private

        def matching_channels(profile)
          channels = identity_candidates(profile)
          channels.empty? ? email_candidates(profile) : channels
        end

        def identity_candidates(profile)
          return [] unless @record.provider == 'microsoft'

          raise Invalid unless profile['id'].is_a?(String) && profile['id'].match?(%r{\A[A-Za-z0-9_=+/-]{1,2048}\z})

          channels = Channel::Email.where(provider: 'microsoft').where("provider_config->'toybaco_microsoft'->>'subject_id' = ?",
                                                                       profile['id']).limit(2).to_a
          raise Forbidden if channels.any? { |channel| channel.account_id != @record.account_id }

          channels
        end

        def email_candidates(profile)
          email = if @record.provider == 'gmail'
                    profile['emailAddress']
                  else
                    profile['mail'].presence || profile['userPrincipalName']
                  end
          raise Invalid unless email.is_a?(String) && email.bytesize <= 320 && email.match?(URI::MailTo::EMAIL_REGEXP)

          @record.account.email_channels.where('LOWER(email) = :email OR LOWER(imap_login) = :email', email: email.downcase).limit(2).to_a
        end
      end
    end
  end
end
