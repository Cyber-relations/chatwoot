# frozen_string_literal: true

require_relative 'draft_access'
require_relative '../postiz_sync'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    module PostDraftAccess
      module_function

      def allowed?(account, user, organization_id)
        return false unless account&.active? && user&.confirmed?

        return false unless eligible?(account)

        PostizSync.access_context(user: user, account: account, organization_id: organization_id).present?
      rescue PostizSync::Error
        false
      end

      def eligible?(account)
        terms = Entitlements.for_account(account)
        terms&.dig('ai_meter') == GrowthTerms::METER && terms.dig('features', 'ai_reply') == true &&
          terms.dig('features', 'posting') == true && PostizSync.enabled?(account)
      end
    end
  end
end
