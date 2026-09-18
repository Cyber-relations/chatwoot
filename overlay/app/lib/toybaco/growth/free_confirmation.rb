# frozen_string_literal: true

require_relative 'free_registration'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    module FreeConfirmation
      extend ActiveSupport::Concern

      included do
        after_update_commit :activate_toybaco_free_store, if: :saved_change_to_confirmed_at?
      end

      private

      def activate_toybaco_free_store
        return unless confirmed?

        accounts.where("internal_attributes -> 'toybaco_growth_registration' ->> 'phase' = 'email_pending'").find_each do |account|
          FreeRegistration.new.activate!(self, account)
        end
      rescue ActiveRecord::ActiveRecordError
        # Confirmation has committed; recover without asking the user to use an
        # already-consumed email link or issuing a second registration.
        Toybaco::FreeActivationJob.perform_later(id)
      end
    end
  end
end
