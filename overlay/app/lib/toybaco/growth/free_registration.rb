# frozen_string_literal: true

require_relative '../entitlements'
require_relative '../ai_reply_mode'
require_relative '../legal_terms'
require_relative 'free_period'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class FreeRegistration
      KEY = 'toybaco_growth_registration'
      OWNER_KEY = 'toybaco_billing_owner_user_id'

      class Unavailable < StandardError; end

      def self.enabled?
        version = PlanCatalog.default.data['free_registration_version']
        return false unless version.is_a?(String) && !version.empty?

        terms = PlanCatalog.default.definition('free', version)
        terms['billing_kind'] == 'free' && terms['cycles'].empty? && terms['sellable'] == true
      rescue PlanCatalog::Invalid
        false
      end

      def initialize(now: Time.now.utc, catalog: PlanCatalog.default)
        @now = now
        @catalog = catalog
      end

      def register!(attributes)
        raise Unavailable, '無料登録は現在準備中です。' unless self.class.enabled?

        ActiveRecord::Base.transaction do
          user, account = I18n.with_locale(:ja) { build_account(attributes) }
          prepare!(user, account)
          [user, account]
        end
      end

      def activate!(user, account)
        account.with_lock do
          saved = Entitlements.attributes(account)[KEY]
          return unless pending_for?(saved, user, account)

          state = saved.merge('phase' => 'active', 'free_anchor' => @now.iso8601, 'activated_at' => @now.iso8601)
          account.update!(status: 'active', internal_attributes: Entitlements.attributes(account).merge(KEY => state))
          FreePeriod.new(account, now: @now).refresh!
        end
      end

      private

      def build_account(attributes)
        AccountBuilder.new(account_name: attributes.fetch(:account_name), user_full_name: attributes.fetch(:user_full_name),
                           email: attributes.fetch(:email), user_password: attributes.fetch(:password), locale: 'ja').perform
      end

      def prepare!(user, account)
        version = @catalog.data.fetch('free_registration_version')
        terms = @catalog.definition('free', version)
        contract = Entitlements.snapshot_for(terms, cycle: nil, catalog: @catalog)
        Entitlements.apply!(account, contract, catalog: @catalog)
        # terms_version は従来どおり無料プランのカタログ版。利用規約の版は legal_terms_version に分けて残す。
        state = { 'phase' => 'email_pending', 'version' => version, 'owner_id' => user.id,
                  'registered_at' => @now.iso8601, 'terms_version' => version,
                  'legal_terms_version' => LegalTerms::VERSION, 'terms_accepted_at' => @now.iso8601 }
        updates = { KEY => state, OWNER_KEY => user.id, AiReplyMode::ATTR => AiReplyMode::DRAFT }
        account.update!(status: 'suspended', internal_attributes: Entitlements.attributes(account).merge(updates),
                        custom_attributes: (account.custom_attributes || {}).merge('onboarding_step' => nil))
        LegalTerms.record!(account, route: 'free_registration', accepted_at: @now, user_id: user.id)
        activate!(user, account) if user.confirmed?
      end

      def pending_for?(saved, user, account)
        saved.is_a?(Hash) && saved['phase'] == 'email_pending' && saved['owner_id'] == user.id && user.confirmed? &&
          account.account_users.exists?(user_id: user.id, role: :administrator)
      end
    end
  end
end
