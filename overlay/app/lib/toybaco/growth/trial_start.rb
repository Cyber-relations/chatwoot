# frozen_string_literal: true

require_relative '../billing_access'
require_relative 'ai_grants'
require_relative 'trial_connection'
require_relative 'trial_example'
require_relative '../ai_reply_mode'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class TrialStart
      DAYS = 14
      UNITS = 100
      class Unavailable < StandardError; end

      def initialize(account, user, now: Time.now.utc)
        @account = account
        @user = user
        @now = now
      end

      def start!(example_id:, revision:, confirmed:)
        @account.with_lock do
          authorize!
          previous = Toybaco::GrowthTrial.find_by(account_id: @account.id)
          return previous if previous

          example = example!(example_id, revision, confirmed)
          identities = identities!(example)
          create!(example, revision, identities)
        end
      rescue ActiveRecord::RecordNotUnique
        raise Unavailable, 'この接続先では体験済みです。元の店舗をご利用ください。'
      end

      private

      def authorize!
        access = BillingAccess.permissions(@account, @user)
        allowed = @account.active? && @user&.confirmed? && access[:can_manage_billing] && eligible_plan?
        raise Unavailable, '体験はFree・Lightの契約者が開始できます。' unless allowed
      end

      def eligible_plan?
        terms = Entitlements.for_account(@account)
        terms&.dig('ai_meter') == GrowthTerms::METER && terms.dig('features', 'ai_auto_reply') != true
      end

      def example!(id, revision, confirmed)
        facts = StoreFacts.new(@account).read
        valid = confirmed == true && facts['confirmed'] && facts['revision'] == revision
        example = TrialExample.new(@account).find(id, revision: revision) if valid
        raise Unavailable, '現在の店舗情報で作成した回答例を確認してください。' unless example

        example
      end

      def identities!(example)
        raise Unavailable, '接続とAI設定を確認してください。' unless TrialConnection.identity(example.inbox)

        identities = @account.inboxes.includes(:channel, :agent_bot_inbox).filter_map { |inbox| TrialConnection.identity(inbox) }.uniq
        raise Unavailable, '受信箱を接続してください。' if identities.empty?

        identities
      end

      def create!(example, revision, identities)
        trial = Toybaco::GrowthTrial.create!(account_id: @account.id, example_id: example.id, facts_revision: revision,
                                             starts_at: @now, ends_at: @now + DAYS.days)
        identities.each { |identity| trial.identities.create!(identity) }
        AiGrants.new(@account).issue!(source: 'trial', source_key: "trial:#{trial.id}", units: UNITS,
                                      starts_at: trial.starts_at, ends_at: trial.ends_at)
        AiReplyMode.write_to!(@account, AiReplyMode::AUTO)
        trial
      end
    end
  end
end
