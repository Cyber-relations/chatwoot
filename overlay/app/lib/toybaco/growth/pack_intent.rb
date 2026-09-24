# frozen_string_literal: true

require_relative 'pack_identity'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class PackIntent < PurchaseIntent
      REQUEST_KEY = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
      PENDING = %w[prepared open payment_pending payment_review].freeze

      def initialize(account, user, request_key: nil, **)
        super(account, user, **)
        @request_key = request_key
      end

      def saved
        order = @request_key ? orders.find_by(request_key: @request_key) : orders.order(id: :desc).first
        order&.payload
      end

      def prepare!(selection)
        valid = selection.is_a?(Hash) && selection.keys == ['request_key'] && selection['request_key'].to_s.match?(REQUEST_KEY)
        raise Unavailable, '購入内容を確認してください。' unless valid

        @request_key = selection.fetch('request_key')
        @account.with_lock do
          authorize!
          previous = saved
          next previous if previous
          raise Unavailable, '先に開いた追加購入の決済を確認してください。' if orders.exists?(state: PENDING)

          create_order!(selection)
        end
      end

      def authorize!
        terms = Entitlements.for_account(@account)
        eligible = terms&.dig('ai_meter') == GrowthTerms::METER && terms.dig('features', 'ai_pack_purchase') == true
        allowed = billing_owner? && eligible && PackCatalog.available? && !RenewalTransition.pending?(@account)
        raise Unavailable, '追加パックはStandard・Proの契約者が購入できます。' unless allowed
      end

      def authorize_cancel!
        raise Unavailable, '契約者の権限を確認できません。' unless billing_owner?
      end

      def save!(intent)
        order = orders.find_by!(nonce: intent.fetch('nonce'), request_key: intent.fetch('request_key'))
        order.update!(payload: intent, state: intent.fetch('state'), session_id: intent['session_id'])
      end

      def creation_key(saved)
        "toybaco-pack:#{saved.fetch('nonce')}"
      end

      def expiration_key(saved)
        "toybaco-pack-expire:#{saved.fetch('nonce')}"
      end

      def nonce_metadata_key
        'toybaco_pack_nonce'
      end

      def terminal_states
        %w[complete expired refunded payment_review]
      end

      def verify_session!(session, saved)
        PackIdentity.verify!(session, saved, account_id: @account.id)
      end

      private

      def billing_owner?
        access = BillingAccess.permissions(@account, @user)
        @account.active? && @user&.confirmed? && access[:can_manage_billing]
      end

      def orders
        Toybaco::GrowthPackOrder.where(account_id: @account.id)
      end

      def create_order!(selection)
        price = PackCatalog.resolve(client: @client, environment: @environment)
        customer = Entitlements.attributes(@account)['toybaco_stripe_customer_id'].to_s
        raise Unavailable, 'ご契約の決済情報を確認してください。' unless customer.match?(Checkout::Catalog::CUSTOMER_ID)

        intent = build_intent(price, customer, selection)
        intent['params'] = PackForm.build(@account.id, intent, environment: @environment)
        orders.create!(owner_id: @user.id, request_key: @request_key, nonce: intent.fetch('nonce'), state: 'prepared', payload: intent)
        intent
      end

      def build_intent(price, customer, selection)
        terms = PackCatalog.terms
        { 'nonce' => SecureRandom.hex(24), 'state' => 'prepared', 'owner_id' => @user.id, 'selection' => selection,
          'request_key' => @request_key, 'price_id' => price.fetch('id'), 'customer_id' => customer,
          'created_at' => @now.to_i, 'expires_at' => @now.to_i + 3600, 'version' => PackCatalog::VERSION,
          'amount' => terms.fetch('amount'), 'units' => terms.fetch('generations'), 'days' => terms.fetch('expires_after_days'),
          'livemode' => price.fetch('livemode') }
      end
    end
  end
end
