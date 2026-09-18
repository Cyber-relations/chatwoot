# frozen_string_literal: true

require_relative '../entitlements'
require_relative '../ai_reply_mode'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class TrialLifecycle
      def initialize(account, now: Time.now.utc)
        @account = account
        @now = now
      end

      def refresh!
        @account.with_lock do
          trial = Toybaco::GrowthTrial.find_by(account_id: @account.id, completed_at: nil)
          return unless trial

          grant = Toybaco::GrowthAiGrant.find_by(account_id: @account.id, source: 'trial', source_key: "trial:#{trial.id}")
          reason = completion_reason(trial, grant)
          complete!(trial, grant, reason) if reason
        end
      end

      private

      def completion_reason(trial, grant)
        return 'upgraded' if Entitlements.for_account(@account)&.dig('features', 'ai_auto_reply') == true
        return 'expired' if trial.ends_at <= @now
        return 'unavailable' unless grant

        'limit_reached' if grant.used >= grant.units && !pending_delivery?(grant)
      end

      def pending_delivery?(grant)
        grant.operations.where(state: 'consumed').where('lease_expires_at > ?', @now).any? do |operation|
          id = operation.result_reference.to_s.delete_prefix('message:')
          state = @account.messages.find_by(id: id)&.additional_attributes&.dig('toybaco_growth_reply', 'state')
          %w[queued dispatching].include?(state)
        end
      end

      def complete!(trial, grant, reason)
        grant.update!(revoked_at: @now) if grant && !grant.revoked_at
        trial.update!(completed_at: @now, completion_reason: reason)
        return if reason == 'upgraded'

        AiReplyMode.write_to!(@account, AiReplyMode::DRAFT)
        @account.conversations.where(status: :pending).find_each(&:open!)
      end
    end
  end
end
