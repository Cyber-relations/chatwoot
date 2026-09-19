# frozen_string_literal: true

require_relative 'pack_receipt'
require_relative 'ai_grants'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class PackFulfillment
      def initialize(client:)
        @client = client
      end

      def complete!(session_id, event_id)
        session = @client.retrieve_checkout_session(session_id)
        order = locate!(session)
        Account.transaction do
          account = Account.lock.find(order.account_id)
          order.reload
          PackIdentity.verify!(session, order.payload, account_id: account.id)
          return order.state if %w[complete refunded payment_review].include?(order.state)

          documents = documents(session_id, event_id)
          paid_at = PackReceipt.new(account_id: account.id, saved: order.payload, documents: documents).verify!
          apply!(account, order, documents, paid_at)
          'complete'
        end
      end

      private

      def locate!(session)
        nonce = session.dig('metadata', 'toybaco_pack_nonce').to_s
        raise PurchaseIntent::Unavailable, '追加購入の記録が見つかりません。' unless nonce.match?(/\A[0-9a-f]{48}\z/)

        Toybaco::GrowthPackOrder.find_by!(nonce: nonce)
      end

      def documents(session_id, event_id)
        session = @client.retrieve_checkout_session(session_id)
        { session: session, event: @client.retrieve_event(event_id),
          payment: @client.retrieve_payment_intent(session.fetch('payment_intent')),
          lines: @client.checkout_session_line_items(session_id) }
      end

      def apply!(account, order, documents, paid_at)
        saved = order.payload
        payment_id = documents.fetch(:payment).fetch('id')
        AiGrants.new(account).issue!(source: 'pack', source_key: "stripe_pack:#{payment_id}", units: saved.fetch('units'),
                                     starts_at: paid_at, ends_at: paid_at + saved.fetch('days').days)
        updated = saved.except('params', 'url').merge('state' => 'complete', 'session_id' => documents.fetch(:session).fetch('id'),
                                                      'paid_total' => documents.fetch(:session).fetch('amount_total'),
                                                      'paid_at' => paid_at.iso8601, 'ends_at' => (paid_at + saved.fetch('days').days).iso8601)
        order.update!(payload: updated, state: 'complete', session_id: updated.fetch('session_id'), payment_intent_id: payment_id,
                      event_id: documents.fetch(:event).fetch('id'), paid_at: paid_at)
      end
    end
  end
end
