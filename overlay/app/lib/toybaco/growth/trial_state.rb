# frozen_string_literal: true

require_relative 'trial_start'
require_relative 'trial_lifecycle'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class TrialState
      def initialize(account)
        @account = account
      end

      def read
        TrialLifecycle.new(@account).refresh!
        return { 'state' => 'included' } if Entitlements.for_account(@account)&.dig('features', 'ai_auto_reply') == true

        trial = Toybaco::GrowthTrial.find_by(account_id: @account.id)
        return preparation unless trial

        grant = Toybaco::GrowthAiGrant.find_by(account_id: @account.id, source: 'trial', source_key: "trial:#{trial.id}")
        used = grant&.used || TrialStart::UNITS
        { 'state' => trial.completed_at ? 'completed' : 'active', 'ends_at' => trial.ends_at.utc.iso8601,
          'remaining' => [TrialStart::UNITS - used, 0].max, 'used' => used, 'reason' => trial.completion_reason,
          'notices' => TrialNotice.notices(@account), 'compensated_seconds' => trial.compensated_seconds }
      end

      private

      def preparation
        facts = StoreFacts.new(@account).read
        examples = facts['confirmed'] ? TrialExample.new(@account).list(revision: facts['revision']) : []
        ready = examples.select { |message| TrialConnection.identity(message.inbox) }
        { 'state' => 'not_started', 'revision' => facts['revision'], 'confirmed_facts' => facts['confirmed'],
          'examples' => ready.map do |message|
            { 'id' => message.id, 'content' => message.content.delete_prefix(ReplyResult::DRAFT_PREFIX),
              'inbox_name' => message.inbox.name, 'conversation_id' => message.conversation.display_id }
          end }
      end
    end
  end
end
