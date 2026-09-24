# frozen_string_literal: true

require 'securerandom'
require_relative '../billing_access'
require_relative '../checkout'
require_relative 'renewal_transition'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class PurchaseIntent
      KEY = 'toybaco_growth_purchase'
      VERSION = '2026-09-18.1'
      class Unavailable < StandardError; end

      def initialize(account, user, client:, environment: ENV, now: Time.now.utc)
        @account = account
        @user = user
        @client = client
        @environment = environment
        @now = now
      end

      def self.saved(account)
        value = Entitlements.attributes(account)[KEY]
        value.is_a?(Hash) ? value : nil
      end

      def saved
        self.class.saved(@account)
      end

      def creation_key(saved)
        "toybaco-purchase:#{saved.fetch('nonce')}"
      end

      def expiration_key(saved)
        "toybaco-expire:#{saved.fetch('nonce')}"
      end

      def nonce_metadata_key
        'toybaco_purchase_nonce'
      end

      def terminal_states
        %w[complete expired]
      end

      def verify_session!(session, saved)
        PurchaseIdentity.verify!(session, saved, account_id: @account.id)
      end

      def prepare!(selection)
        @account.with_lock do
          authorize!
          previous = self.class.saved(@account)
          next resume(previous, selection) if previous && previous['state'] != 'expired'

          terms, price = resolve(selection)
          intent = build(terms, price, selection)
          save!(intent)
          intent
        end
      end

      def authorize!
        access = BillingAccess.permissions(@account, @user)
        allowed = @user&.confirmed? && access[:can_manage_billing] && free_store? && !RenewalTransition.pending?(@account)
        raise Unavailable, 'この店舗では新規購入を開始できません。' unless allowed
      end

      def authorize_cancel!
        authorize!
      end

      def save!(intent)
        @account.update!(internal_attributes: Entitlements.attributes(@account).merge(KEY => intent))
      end

      private

      def free_store?
        contract = Entitlements.contract_for(@account)
        attrs = Entitlements.attributes(@account)
        @account.active? && contract&.dig('plan_id') == 'free' && contract.dig('entitlements', 'ai_meter') == GrowthTerms::METER &&
          attrs['toybaco_subscription_id'].blank? && !attrs.key?(StoreFulfillment::PURCHASE)
      end

      def resume(previous, selection)
        raise Unavailable, '先に開いた決済を確認してください。プランを選び直す場合は、その決済を終了できます。' unless previous['selection'] == selection && previous['owner_id'] == @user.id

        previous
      end

      def resolve(selection)
        unless selection.keys.sort == %w[cycle plan_id plan_version] && selection['plan_version'] == VERSION &&
               %w[light standard pro].include?(selection['plan_id']) && %w[month year].include?(selection['cycle'])
          raise Unavailable, '購入内容を確認してください。'
        end

        terms = PlanCatalog.default.sale(selection['plan_id'], selection['cycle'], version: selection['plan_version'])
        price = Checkout::Resolver.price_for(terms, selection['cycle'], client: @client, environment: @environment)
        Checkout.assert_checkout_price!(price, terms, selection['cycle'], @environment)
        [terms, price]
      end

      def build(terms, price, selection)
        nonce = SecureRandom.hex(24)
        intent = { 'nonce' => nonce, 'state' => 'prepared', 'owner_id' => @user.id, 'selection' => selection,
                   'price_id' => price.fetch('id'), 'created_at' => @now.to_i, 'expires_at' => @now.to_i + 3600,
                   'amount' => terms.fetch('cycles').fetch(selection.fetch('cycle')).fetch('amount'),
                   'livemode' => @environment.fetch('TOYBACO_STRIPE_MODE', 'live') == 'live' }
        intent.merge('params' => PurchaseForm.build(account: @account, user: @user, intent: intent, environment: @environment))
      end
    end
  end
end

require_relative 'purchase_form'
