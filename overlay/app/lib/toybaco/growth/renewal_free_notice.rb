# frozen_string_literal: true

require_relative 'renewal_reminder'
require_relative 'renewal_grace'
require_relative 'renewal_transition'
require_relative 'free_return_record'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # The third renewal notice: after the first reminder and the expired one, the store returned to Free
    # because its renewal payment never arrived (renewal dispatch free_completed). The dispatch enqueues it
    # after the Free write committed; this sends it at most once per transition, and only while the store is
    # still on Free (a purchase after the return keeps the completed journal and the receipt). The attempt is
    # the 'free_transition' stage of the renewal reminder's record for the same renewal (the failure's
    # subscription and term, which the Free return archives in its receipt), with the same states. Any failure
    # after the claim is uncertain and never sent again: a changed recipient, transition or contract, a mail
    # that cannot be built, or a delivery with no known result. A failure before the claim committed (reading
    # the flag, the lock or the store, or writing the claim) is raised again for the job's retry: the retry sends
    # it only when no claim is recorded, so it cannot send it twice. A period-end cancellation is not notified here.
    class RenewalFreeNotice
      STAGE = 'free_transition'
      # The hourly reminder sweep recovers a notice the dispatch could not enqueue only for a Free return of the
      # last 7 days: a later notice would be too late to be useful.
      WINDOW = 7 * 24 * 60 * 60

      # The store is still on Free: a purchase after the return writes a paid contract and binds its
      # subscription, while the completed journal and the receipt of the return stay.
      def self.still_free?(account)
        contract = Entitlements.contract_for(account)
        contract.is_a?(Hash) && contract['plan_id'] == 'free' && Entitlements.attributes(account)['toybaco_subscription_id'].blank?
      end

      # Stores the sweep reads: a completed transition journal. Only the journal state is narrowed in SQL (no cast),
      # so one malformed value cannot fail the sweep; pending? checks the rest.
      def self.candidates
        Account.where("internal_attributes -> 'toybaco_growth_renewal_transition' ->> 'state' = 'free_completed'")
      end

      # Read only, with no lock, write or log: the notice of the store's current Free return is not recorded yet
      # (a renewal failure's return of the last WINDOW, the store still on Free, and no free_transition stage in the
      # reminder's record of that renewal; a record of another renewal is replaced by the claim). The claim in
      # perform decides again under the lock, so a store this lets through is still sent at most once.
      def self.pending?(account, now:)
        attrs = Entitlements.attributes(account)
        journal = attrs[RenewalTransition::KEY]
        return false unless account.active? && failure_return?(journal) && recent?(journal, now) && still_free?(account)

        failure = archived_failure(account, journal)
        failure ? !stage_recorded?(attrs[RenewalReminder::KEY], renewal_of(failure)) : false
      rescue FreeReturnRecord::Invalid
        false
      end

      # A completed journal of a renewal failure's return (no cancel binding), shared with the claim.
      def self.failure_return?(journal)
        journal.is_a?(Hash) && journal['state'] == 'free_completed' && journal['binding'].is_a?(Hash) && !journal['binding'].key?('cancel')
      end

      # The failure record the return of this journal archived in its receipt, shared with the claim. Raises
      # FreeReturnRecord::Invalid when the receipt no longer reads; the caller decides whether to log it.
      def self.archived_failure(account, journal)
        receipt = FreeReturnRecord.current(account)
        failure = receipt && receipt['transition_id'] == journal['id'] && receipt.dig('billing_history', RenewalGrace::FAILURE_KEY)
        failure if failure.is_a?(Hash) && failure['subscription_id'].is_a?(String) && failure['term_start'].is_a?(Integer)
      end

      def self.renewal_of(failure)
        "#{failure['subscription_id']}:#{failure['term_start']}"
      end

      def self.recent?(journal, now)
        journal['observed_at'].is_a?(Integer) && now.to_i - WINDOW <= journal['observed_at']
      end

      def self.stage_recorded?(record, renewal)
        record.is_a?(Hash) && record['renewal'] == renewal && record['stages'].is_a?(Hash) && record['stages'].key?(STAGE)
      end
      private_class_method :recent?, :stage_recorded?

      def initialize(account, now: Time.now.utc)
        @account = account
        @now = now
      end

      def perform
        return unless RenewalReminder.enabled? && claim!

        Toybaco::GrowthRenewalMailer.free_transition_notice(@account.id, @recipient_id, @transition_id).deliver_now
        finish!('attempted')
      rescue StandardError => e
        raise unless @claimed

        finish!('uncertain')
        Rails.logger.warn("toybaco_renewal_free_notice_uncertain account=#{@account.id} class=#{e.class.name}")
      end

      private

      # The claim counts only after its transaction committed: a failure inside it (the write or the COMMIT)
      # leaves @claimed unset and is raised again for the retry, which sends it unless the record is there.
      def claim!
        claimed = @account.with_lock do
          next false unless eligible?

          prepare_record
          next false if @record['stages'].key?(STAGE)

          owner = TrialNotice.owner(@account)
          next false unless owner

          claim_delivery!(owner)
        end
        @claimed = claimed == true
      end

      # The current Free return of a renewal failure: its completed failure journal (no cancel binding), a store
      # still on Free, and the receipt of that transition, which keeps the failure record it archived.
      def eligible?
        journal = Entitlements.attributes(@account)[RenewalTransition::KEY]
        return false unless @account.active? && self.class.failure_return?(journal) && self.class.still_free?(@account)

        failure = failure_of(journal)
        return false unless failure

        @transition_id = journal['id']
        @renewal = self.class.renewal_of(failure)
        true
      end

      def failure_of(journal)
        self.class.archived_failure(@account, journal)
      rescue FreeReturnRecord::Invalid
        # The receipt no longer reads (the Free terms changed after the return): not sent, not recorded.
        Rails.logger.warn("toybaco_renewal_free_notice_skipped account=#{@account.id} reason=receipt-invalid")
        nil
      end

      # The reminder's record of this renewal keeps its stages; any other record is replaced, as the reminder does.
      def prepare_record
        previous = Entitlements.attributes(@account)[RenewalReminder::KEY]
        same = previous.is_a?(Hash) && previous['renewal'] == @renewal && previous['stages'].is_a?(Hash)
        @record = same ? previous.deep_dup : { 'renewal' => @renewal, 'stages' => {} }
      end

      def claim_delivery!(owner)
        @recipient_id = owner.id
        @token = SecureRandom.hex(16)
        @record['stages'][STAGE] = { 'state' => 'dispatching', 'token' => @token, 'user_id' => owner.id,
                                     'transition_id' => @transition_id, 'attempted_at' => @now.to_i }
        @account.update!(internal_attributes: Entitlements.attributes(@account).merge(RenewalReminder::KEY => @record))
        true
      end

      def finish!(state)
        @account.with_lock do
          attrs = Entitlements.attributes(@account)
          record = attrs[RenewalReminder::KEY]
          return unless record.is_a?(Hash) && record['renewal'] == @renewal && record.dig('stages', STAGE, 'token') == @token

          record['stages'][STAGE]['state'] = state
          record['stages'][STAGE].delete('token')
          @account.update!(internal_attributes: attrs.merge(RenewalReminder::KEY => record))
        end
      end
    end
  end
end
