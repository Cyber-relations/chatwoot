# frozen_string_literal: true

require_relative 'pack_identity'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # Read provider-confirmed refunds/disputes; never initiate a refund here.
    class PackRefund
      def initialize(client:)
        @client = client
      end

      def call(charge_id)
        charge = @client.retrieve_charge(charge_id)
        order = locate(charge)
        return 'ignored' unless order

        Account.transaction do
          Account.lock.find(order.account_id)
          order.reload
          current = @client.retrieve_charge(charge_id)
          verify!(current, order)
          next order.state if order.state == 'refunded'

          state = refund_state(current)
          next 'unchanged' unless state

          record!(order, current, state)
          state
        end
      end

      private

      def locate(charge)
        payment_id = charge['payment_intent'].to_s
        return unless payment_id.match?(/\Api_[A-Za-z0-9]+\z/)

        found = Toybaco::GrowthPackOrder.find_by(payment_intent_id: payment_id)
        return found if found

        nonce = charge.dig('metadata', 'toybaco_pack_nonce').to_s
        Toybaco::GrowthPackOrder.find_by(nonce: nonce) if nonce.match?(/\A[0-9a-f]{48}\z/)
      end

      def verify!(charge, order)
        saved = order.payload
        expected = { 'currency' => 'jpy', 'customer' => saved.fetch('customer_id'), 'livemode' => saved.fetch('livemode') }
        expected['payment_intent'] = order.payment_intent_id if order.payment_intent_id
        matching = expected.all? { |key, value| charge[key] == value } && PackIdentity.metadata_matches?(charge, saved, order.account_id)
        raise PurchaseIntent::Unavailable, '返金と追加購入の記録が一致しません。' unless matching
      end

      def refund_state(charge)
        refunded = charge['amount_refunded']
        total = charge['amount']
        return 'payment_review' if charge['disputed'] == true
        return unless [refunded, total].all? { |amount| amount.is_a?(Integer) && amount.positive? }

        charge['refunded'] == true && refunded == total ? 'refunded' : 'payment_review'
      end

      def record!(order, charge, state)
        stamp = Time.now.utc
        payment_id = charge.fetch('payment_intent')
        grant = Toybaco::GrowthAiGrant.find_by(account_id: order.account_id, source: 'pack', source_key: "stripe_pack:#{payment_id}")
        grant.update!(revoked_at: stamp) if grant && !grant.revoked_at
        saved = order.payload.except('params', 'url').merge('state' => state)
        order.update!(state: state, payload: saved, payment_intent_id: payment_id, refunded_at: state == 'refunded' ? stamp : nil)
      end
    end
  end
end
