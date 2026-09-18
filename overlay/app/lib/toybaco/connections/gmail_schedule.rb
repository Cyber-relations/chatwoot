# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    module GmailSchedule
      def perform
        super
        Channel::Email.where(provider: 'google').where("provider_config ? 'toybaco_gmail'").find_each do |channel|
          next unless Gmail.allowed?(channel.account) && !channel.reauthorization_required?

          Toybaco::GmailFetchJob.perform_later(channel.id)
        end
      end
    end
  end
end
