# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    module MicrosoftSchedule
      def perform
        super
        Channel::Email.where(provider: 'microsoft').where("provider_config ? 'toybaco_microsoft'").find_each do |channel|
          next unless Microsoft.allowed?(channel.account) && !channel.reauthorization_required?

          Toybaco::MicrosoftFetchJob.perform_later(channel.id)
        end
      end
    end
  end
end
