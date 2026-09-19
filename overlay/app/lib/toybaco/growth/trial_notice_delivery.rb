# frozen_string_literal: true

require_relative 'trial_notice'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class TrialNoticeDelivery
      def self.enabled?
        GlobalConfigService.load('TOYBACO_GROWTH_NOTICES_ENABLED', false) == true
      end

      def initialize(notice)
        @notice = notice
        @account = notice.account
      end

      def perform
        return unless self.class.enabled? && claim!

        Toybaco::GrowthTrialMailer.reminder(@notice).deliver_now
        @notice.update!(state: 'attempted')
      rescue StandardError => e
        Rails.logger.warn("toybaco_trial_notice_uncertain notice=#{@notice.id} class=#{e.class}")
        @notice.reload.update!(state: 'uncertain') if @notice.persisted? && @notice.reload.state == 'dispatching'
      end

      private

      def claim!
        @account.with_lock do
          @notice.with_lock do
            return false unless @notice.state == 'queued'
            return cancel! unless valid_recipient? && valid_trial?
            return false unless TrialNotice.due_kinds(@trial, @grant, Time.now.utc).include?(@notice.kind)

            @notice.update!(state: 'dispatching', attempted_at: Time.now.utc)
            true
          end
        end
      end

      def valid_recipient?
        user = User.find_by(id: @notice.user_id)
        @account.active? && user&.confirmed? && BillingAccess.can_view?(@account, user)
      end

      def valid_trial?
        @trial = @notice.trial.reload
        @grant = Toybaco::GrowthAiGrant.find_by(account_id: @account.id, source: 'trial', source_key: "trial:#{@trial.id}")
        return false if Entitlements.for_account(@account)&.dig('features', 'ai_auto_reply') == true

        @trial.account_id == @account.id && TrialNotice.active_trial?(@trial, @grant, Time.now.utc)
      end

      def cancel!
        @notice.update!(state: 'cancelled')
        false
      end
    end
  end
end
