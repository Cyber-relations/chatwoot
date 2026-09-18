# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    module GmailCleanup
      extend ActiveSupport::Concern

      included do
        after_destroy_commit :toybaco_revoke_gmail
      end

      private

      def toybaco_revoke_gmail
        return unless Gmail.connected?(self)

        Toybaco::GmailRevokeJob.perform_later(Gmail.config(self).fetch('credentials'), Gmail.purpose(self))
      end
    end
  end
end
