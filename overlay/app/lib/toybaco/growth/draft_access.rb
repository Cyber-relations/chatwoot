# frozen_string_literal: true

require_relative '../entitlements'
require_relative 'inbox_retention'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    module DraftAccess
      module_function

      def allowed?(account, user, conversation)
        return false unless account.active? && user&.confirmed? && conversation.account_id == account.id

        return false unless eligible_plan?(account)

        membership = account.account_users.find_by(user_id: user.id)
        return false unless membership

        context = { user: user, account: account, account_user: membership }
        ConversationPolicy.new(context, conversation).show?
      end

      def generation_allowed?(account, user, conversation)
        InboxRetention.with_inbox(conversation.inbox) { allowed?(account, user, conversation) }
      rescue InboxRetention::Held, InboxRetention::Busy, InboxRetention::Invalid
        false
      end

      def enabled?
        GlobalConfigService.load('TOYBACO_BUSINESS_AI_ENABLED', false) == true
      end

      def eligible_plan?(account)
        terms = Entitlements.for_account(account)
        terms&.dig('ai_meter') == GrowthTerms::METER && terms.dig('features', 'ai_reply') == true
      end
    end
  end
end
