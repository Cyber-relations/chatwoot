# frozen_string_literal: true

require_relative '../entitlements'
require_relative '../growth/onboarding'
require_relative '../growth/draft_access'
require_relative '../billing_access'
require_relative 'knowledge'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Support
    class Context
      REQUIREMENTS = {
        'member' => :member?, 'active_member' => :active_member?, 'administrator' => :settings?,
        'growth' => :growth?, 'growth_admin' => :growth_admin?,
        'gmail' => :gmail?, 'microsoft' => :microsoft?, 'posting' => :posting?, 'drafts' => :drafts?, 'billing' => :billing?
      }.freeze
      def initialize(account, user)
        @account = account
        @user = user
        @membership = account.account_users.find_by(user_id: user.id)
      end

      def member?
        @user.confirmed? && @membership.present?
      end

      def administrator?
        member? && @membership.administrator?
      end

      def allowed?(requirement)
        check = REQUIREMENTS[requirement]
        member? && check && send(check) == true
      rescue PlanCatalog::Invalid
        false
      end

      def status
        { 'account_active' => @account.active?, 'administrator' => administrator?, 'knowledge_version' => Knowledge::VERSION }
      end

      private

      def active_member?
        member? && @account.active?
      end

      def settings?
        administrator? && @account.active?
      end

      def growth?
        Growth::Onboarding.available?(@account)
      end

      def growth_admin?
        administrator? && growth?
      end

      def gmail?
        growth_admin? && Connections::Gmail.allowed?(@account)
      end

      def microsoft?
        growth_admin? && Connections::Microsoft.allowed?(@account)
      end

      def posting?
        @account.active? && Toybaco::PostizSync.enabled?(@account) && terms&.dig('features', 'posting') == true &&
          Toybaco::PostizSync::ROLE_MAP.key?(@membership.role)
      end

      def drafts?
        Growth::DraftAccess.enabled? && @account.active? && Growth::DraftAccess.eligible_plan?(@account)
      end

      def billing?
        BillingAccess.permissions(@account, @user, membership: @membership).fetch(:can_view_billing)
      end

      def terms
        @terms ||= Entitlements.for_account(@account)
      end
    end
  end
end
