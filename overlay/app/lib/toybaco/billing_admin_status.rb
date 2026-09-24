# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  # An explicit administrator status choice supersedes billing's authority to
  # resume the store, even when the requested status is already suspended.
  module BillingAdminStatus
    STATUS_VALUES = ['active', 'suspended', 0, 1].freeze

    def update
      return super unless toybaco_explicit_status?

      requested_resource.with_lock { super }
    end

    def resource_params
      permitted = super
      return permitted unless toybaco_explicit_status?

      permitted[:internal_attributes] = requested_resource.internal_attributes.merge('toybaco_billing_suspended' => false)
      permitted
    end

    private

    def toybaco_explicit_status?
      STATUS_VALUES.include?(params.dig(:account, :status))
    end

    module Platform
      def update
        return super unless STATUS_VALUES.include?(params[:status])

        @resource.with_lock { super }
      end

      private

      def account_params
        permitted = super
        return permitted unless action_name == 'update' && STATUS_VALUES.include?(params[:status])

        permitted.merge(internal_attributes: @resource.internal_attributes.merge('toybaco_billing_suspended' => false))
      end
    end
  end
end
