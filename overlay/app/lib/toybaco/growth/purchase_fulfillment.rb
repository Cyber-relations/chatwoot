# frozen_string_literal: true

require 'digest'
require_relative 'purchase_intent'
require_relative 'purchase_identity'
require_relative 'paid_coverage'
require_relative 'paid_period'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class PurchaseFulfillment
      def initialize(client:)
        @client = client
      end

      def complete!(session_id)
        initial = @client.retrieve_checkout_session(session_id)
        account_id = initial.dig('metadata', 'toybaco_existing_account_id').to_s
        subscription_id = initial['subscription']
        raise PurchaseIntent::Unavailable, '購入元の店舗を確認できません。' unless account_id.match?(/\A[1-9]\d*\z/)
        return 'payment_pending' unless initial['status'] == 'complete' && subscription_id
        raise PurchaseIntent::Unavailable, '契約を確認できません。' unless subscription_id.to_s.match?(/\Asub_[A-Za-z0-9]+\z/)

        Account.transaction do
          lock_subscription(subscription_id)
          account = Account.lock.find(account_id)
          session = @client.retrieve_checkout_session(session_id)
          apply!(account, session, subscription_id)
        end
      end

      private

      def lock_subscription(id)
        key = Digest::SHA256.digest("toybaco:provision:#{id}").unpack1('q>')
        Account.connection.execute("SELECT pg_advisory_xact_lock(#{key})")
      end

      def apply!(account, session, subscription_id)
        saved = PurchaseIntent.saved(account)
        verify_session!(account, session, saved, subscription_id)
        return 'complete' if completed?(account, saved, subscription_id)

        verify_store!(account, saved, subscription_id)
        subscription = @client.retrieve_subscription(subscription_id)
        contract = verified_contract(subscription, saved, subscription_id)
        return 'payment_pending' unless contract && paid_session?(session, subscription, saved)

        Entitlements.apply!(account, contract, subscription_id: subscription_id)
        PaidPeriod.new(account).observe!(subscription)
        finish!(account, session, saved, subscription)
        'complete'
      end

      def verify_session!(account, session, saved, subscription_id)
        PurchaseIdentity.verify!(session, saved, account_id: account.id)
        matching = session['status'] == 'complete' && session['subscription'] == subscription_id
        raise PurchaseIntent::Unavailable, '契約と決済が一致しません。' unless matching
      end

      def completed?(account, saved, subscription_id)
        saved['state'] == 'complete' && saved['subscription_id'] == subscription_id &&
          Entitlements.attributes(account)['toybaco_subscription_id'] == subscription_id
      end

      def verify_store!(account, saved, subscription_id)
        attrs = Entitlements.attributes(account)
        owner = attrs[BillingAccess::OWNER_KEY] == saved['owner_id'] &&
                account.account_users.exists?(user_id: saved['owner_id'], role: :administrator)
        unbound = !Account.exists?(["internal_attributes ->> 'toybaco_subscription_id' = ?", subscription_id])
        raise PurchaseIntent::Unavailable, '購入元の店舗・契約者・既存契約を確認できません。' unless free_store?(account) && owner && unbound
      end

      def free_store?(account)
        attrs = Entitlements.attributes(account)
        contract = Entitlements.contract_for(account)
        account.active? && !RenewalTransition.pending?(account) && attrs['toybaco_subscription_id'].blank? &&
          !attrs.key?(StoreFulfillment::PURCHASE) && contract&.dig('plan_id') == 'free' &&
          contract.dig('entitlements', 'ai_meter') == GrowthTerms::METER
      end

      def verified_contract(subscription, saved, subscription_id)
        return unless subscription['id'] == subscription_id && subscription['status'] == 'active' && subscription['livemode'] == saved['livemode']

        contract = SubscriptionSync.new(client: @client).resolve(subscription, previous: nil)
        raise PurchaseIntent::Unavailable, '購入内容と請求明細が一致しません。' unless matching_contract?(contract, subscription, saved)

        coverage = PaidCoverage.new(subscription, contract).verified
        contract if current_coverage?(coverage)
      end

      def matching_contract?(contract, subscription, saved)
        keys = %w[plan_id plan_version cycle]
        contract.slice(*keys) == saved.fetch('selection') && contract['stripe_price_id'] == saved['price_id'] &&
          subscription.dig('metadata', 'toybaco_purchase_nonce') == saved['nonce']
      end

      def current_coverage?(coverage)
        coverage && coverage['term_start'] <= Time.now.to_i && coverage['term_end'] > Time.now.to_i && coverage['paid_at'] <= Time.now.to_i
      end

      def paid_session?(session, subscription, saved)
        session['payment_status'] == 'paid' && session['currency'] == 'jpy' && session['amount_subtotal'] == saved['amount'] &&
          [0].include?(session.dig('total_details', 'amount_discount')) && session['customer'].to_s.match?(/\Acus_[A-Za-z0-9]+\z/) &&
          subscription['customer'] == session['customer']
      end

      def finish!(account, session, saved, subscription)
        updated = saved.except('params', 'url').merge('state' => 'complete', 'session_id' => session.fetch('id'),
                                                      'subscription_id' => subscription.fetch('id'), 'completed_at' => Time.now.utc.iso8601)
        values = { PurchaseIntent::KEY => updated, 'toybaco_subscription_status' => 'active',
                   'toybaco_cancel_at_period_end' => subscription['cancel_at_period_end'] == true, 'toybaco_billing_review' => false,
                   'toybaco_stripe_customer_id' => session['customer'] }
        account.update!(internal_attributes: Entitlements.attributes(account).merge(values))
      end
    end
  end
end
