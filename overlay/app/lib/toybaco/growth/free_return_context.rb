# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    module FreeReturnContext
      BILLING_KEYS = %w[toybaco_growth_renewal_failure toybaco_growth_paid_period toybaco_plan_change toybaco_cancel_request].freeze
      PURCHASE_FIELDS = %w[nonce state owner_id selection price_id created_at expires_at amount livemode session_id subscription_id
                           completed_at].freeze

      private

      def checked_context
        attrs = Entitlements.attributes(@account)
        journal = RenewalTransition.new(@account, now: @now, mode: @environment.fetch('TOYBACO_STRIPE_MODE')).current!
        check_store!(attrs, journal)
        posting, inbox = confirmed_holds(journal)
        { 'journal' => journal, 'posting' => posting, 'inbox' => inbox, 'purchase' => checked_purchase(attrs, journal) }
      end

      def check_store!(attrs, journal)
        raise FreeReturnRecord::Invalid unless journal['state'] == 'provider_closed' && !attrs.key?(StoreFulfillment::PURCHASE)
        raise FreeReturnRecord::Invalid if attrs['toybaco_billing_review'] || attrs['toybaco_billing_payment_pending']
        raise FreeReturnRecord::Invalid unless resumable?(attrs)
      end

      def confirmed_holds(journal)
        posting = PostingRetention.new(@account, environment: @environment, clock: -> { @now }).confirmed!
        inbox = InboxRetention.validate!(Entitlements.attributes(@account)[InboxRetention::KEY], account_id: @account.id, now: @now)
        raise FreeReturnRecord::Invalid unless inbox['transition_id'] == journal['id'] && inbox['posting_receipt_hash'] == posting['receipt_hash']
        raise FreeReturnRecord::Invalid unless inbox['keep_inbox_ids'] == journal.dig('retention', 'selected', 'inboxes').sort

        [posting, inbox]
      end

      def resumable?(attrs)
        @account.active? || (@account.suspended? && attrs['toybaco_billing_suspended'] == true && attrs['toybaco_subscription_status'] == 'canceled')
      end

      def checked_purchase(attrs, journal)
        return unless attrs.key?(PurchaseIntent::KEY)

        saved = attrs[PurchaseIntent::KEY]
        raise FreeReturnRecord::Invalid unless purchase_shape?(saved) && purchase_matches?(saved, journal)

        saved.slice(*PURCHASE_FIELDS)
      end

      def purchase_shape?(saved)
        saved.is_a?(Hash) && %w[complete expired].include?(saved['state']) &&
          saved['nonce'].is_a?(String) && saved['nonce'].match?(/\A[0-9a-f]{48}\z/)
      end

      def purchase_matches?(saved, journal)
        saved['state'] == 'expired' || (saved['subscription_id'] == journal.dig('binding', 'subscription_id') &&
          saved['livemode'] == (journal.dig('binding', 'mode') == 'live'))
      end

      def ensure_idle!
        # A remote model request cannot be cancelled by changing local rights.
        # Do not declare Free complete while a known automatic lease is live.
        pending = Toybaco::GrowthAiOperation.where(account_id: @account.id, kind: 'automatic_reply', state: 'reserved')
        raise InboxRetention::Busy if pending.exists?(['lease_expires_at > ?', @now])
      end

      def build_receipt(context)
        attrs = Entitlements.attributes(@account)
        fields = { 'version' => 1, 'account_id' => @account.id, 'transition_id' => context.fetch('journal').fetch('id'),
                   'returned_at' => @now.to_i, 'free_contract' => FreeReturnRecord.free_contract,
                   'source_journal' => context.fetch('journal'), 'posting' => context.fetch('posting'), 'inbox' => context.fetch('inbox'),
                   'settlement' => attrs.fetch(RenewalSettlement::KEY), 'purchase' => context['purchase'],
                   'billing_history' => attrs.slice(*BILLING_KEYS) }
        fields.merge('receipt_hash' => RetentionSnapshot.fingerprint(fields))
      end

      def free_attributes(receipt)
        attrs = Entitlements.attributes(@account).except(*BILLING_KEYS, PurchaseIntent::KEY, 'toybaco_subscription_id')
        completed = receipt.fetch('source_journal').merge('state' => 'free_completed', 'observed_at' => receipt['returned_at'])
        attrs.merge(FreeReturnRecord::KEY => FreeReturnRecord.reference(receipt),
                    RenewalTransition::KEY => completed,
                    'toybaco_subscription_status' => 'canceled', 'toybaco_cancel_at_period_end' => false,
                    'toybaco_billing_suspended' => false, 'toybaco_billing_payment_pending' => false)
      end
    end
  end
end
