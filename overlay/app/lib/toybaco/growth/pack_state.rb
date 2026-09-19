# frozen_string_literal: true

require_relative 'pack_intent'
require_relative 'ai_ledger'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class PackState
      def initialize(account)
        @account = account
      end

      def read(request_key: nil)
        order = order_for(request_key)
        grants = AiLedger.new(@account).summary.fetch('grants').select { |grant| grant['source'] == 'pack' }
        purchase_state(order, request_key).merge('can_purchase' => can_purchase?, 'sale_available' => PackCatalog.available?,
                                                 'pack' => PackCatalog.terms.slice('amount', 'generations', 'expires_after_days'), 'grants' => grants)
      end

      private

      def order_for(request_key)
        orders = Toybaco::GrowthPackOrder.where(account_id: @account.id)
        request_key ? orders.find_by(request_key: request_key) : orders.where(state: PackIntent::PENDING).order(id: :desc).first
      end

      def purchase_state(order, request_key)
        return { 'state' => 'none', 'request_key' => request_key || SecureRandom.uuid } unless order

        { 'state' => order.state, 'request_key' => order.request_key, 'purchase' => order.payload.slice('paid_at', 'ends_at') }
      end

      def can_purchase?
        PackCatalog.available? && Entitlements.for_account(@account)&.dig('features', 'ai_pack_purchase') == true
      end
    end
  end
end
