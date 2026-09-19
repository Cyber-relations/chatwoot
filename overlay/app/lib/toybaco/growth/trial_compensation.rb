# frozen_string_literal: true

require_relative 'trial_outage_window'
require_relative '../entitlements'
require_relative '../ai_reply_mode'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # Internal operations only. The caller must first confirm Toybaco's outage
    # and affected accounts against the report. No customer/AI endpoint exists.
    class TrialCompensation
      FIELDS = %i[incident_key report_digest operator_reference starts_at ends_at].freeze
      class Conflict < StandardError; end

      def initialize(account, now: Time.now.utc)
        @account = account
        @now = now
      end

      def apply!(confirmed:, **attributes)
        validate!(confirmed, attributes)
        @account.with_lock do
          record!(attributes)
          trial = Toybaco::GrowthTrial.find_by(account_id: @account.id)
          grant = grant_for(trial)
          return { 'result' => 'recorded', 'seconds_added' => 0 } unless eligible?(trial, grant)

          extend!(trial, grant)
        end
      end

      private

      def validate!(confirmed, attributes)
        raise ArgumentError, 'confirmed incident fields required' unless confirmed == true && attributes.keys.sort == FIELDS.sort

        raise ArgumentError, 'invalid confirmed outage interval' unless valid_interval?(attributes[:starts_at], attributes[:ends_at])
      end

      def valid_interval?(first, last)
        [first, last].all? { |time| time.is_a?(Time) && time.nsec.zero? } && last > first && last <= @now
      end

      def outages
        Toybaco::GrowthTrialOutage.where(account_id: @account.id)
      end

      def record!(attributes)
        previous = outages.find_by(incident_key: attributes[:incident_key])
        if previous
          raise Conflict, 'incident differs from confirmed record' unless attributes.all? { |key, value| previous.public_send(key) == value }

          return previous
        end
        outages.create!(attributes.merge(confirmed_at: @now))
      end

      def grant_for(trial)
        return unless trial

        Toybaco::GrowthAiGrant.find_by(account_id: @account.id, source: 'trial', source_key: "trial:#{trial.id}")
      end

      def eligible?(trial, grant)
        return false unless @account.active? && recoverable?(trial, grant)

        terms = Entitlements.for_account(@account)
        terms&.dig('ai_meter') == GrowthTerms::METER && terms.dig('features', 'ai_auto_reply') != true
      end

      def recoverable?(trial, grant)
        return false unless trial && grant && grant.used < grant.units
        return false unless [nil, 'expired'].include?(trial.completion_reason)

        !grant.revoked_at || trial.completion_reason == 'expired'
      end

      def extend!(trial, grant)
        base = trial.compensation_base_ends_at || trial.ends_at
        verify_previous!(trial, grant, base)
        ending = TrialOutageWindow.deadline(starts_at: trial.starts_at, base_ends_at: base, intervals: outages.pluck(:starts_at, :ends_at))
        added = (ending - trial.ends_at).to_i
        return { 'result' => 'unchanged', 'seconds_added' => 0 } unless added.positive?

        update_deadline!(trial, grant, base, ending)
        { 'result' => 'extended', 'seconds_added' => added, 'ends_at' => ending.utc.iso8601 }
      end

      def verify_previous!(trial, grant, base)
        matches = grant.ends_at == trial.ends_at && trial.ends_at == base + trial.compensated_seconds
        raise Conflict, 'trial deadline differs from compensation record' unless matches
      end

      def update_deadline!(trial, grant, base, ending)
        already_expired = trial.ends_at <= @now
        reopening = trial.completion_reason == 'expired' && ending > @now
        values = { ends_at: ending, compensation_base_ends_at: base, compensated_seconds: (ending - base).to_i }
        if reopening
          values[:completed_at] = nil
          values[:completion_reason] = nil
        end
        trial.update!(values)
        grant.update!(ends_at: ending, revoked_at: reopening ? nil : grant.revoked_at)
        # The expiry sweep may be delayed; elapsed time also fences AUTO.
        AiReplyMode.write_to!(@account, AiReplyMode::DRAFT) if already_expired
      end
    end
  end
end
