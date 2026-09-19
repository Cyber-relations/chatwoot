# frozen_string_literal: true

require_relative 'pack_identity'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # Checkout's paid completion event supplies a durable payment-success time.
    # Session, line item and current captured charge must independently agree.
    class PackReceipt
      def initialize(account_id:, saved:, documents:, now: Time.now.utc)
        @account_id = account_id
        @saved = saved
        @session = documents.fetch(:session)
        @event = documents.fetch(:event)
        @payment = documents.fetch(:payment)
        @lines = documents.fetch(:lines)
        @now = now
      end

      def verify!
        PackIdentity.verify!(@session, @saved, account_id: @account_id)
        unless paid_session? && matching_event? && matching_payment? && matching_line?
          raise PurchaseIntent::Unavailable, '追加購入の入金・明細を確認しています。時間をおいて再度ご確認ください。'
        end

        Time.at(@event.fetch('created')).utc
      rescue KeyError, TypeError, ArgumentError
        raise PurchaseIntent::Unavailable, '追加購入の入金記録を確認できません。'
      end

      private

      def exact?(object, values)
        object.is_a?(Hash) && values.all? { |key, value| object[key] == value }
      end

      def paid_session?
        exact?(@session, 'status' => 'complete', 'payment_status' => 'paid', 'currency' => 'jpy', 'amount_subtotal' => @saved.fetch('amount')) &&
          exact?(@session['automatic_tax'], 'enabled' => true, 'status' => 'complete') && matching_total?
      end

      def matching_total?
        details = @session['total_details']
        return false unless exact?(details, 'amount_discount' => 0, 'amount_shipping' => 0)

        tax = details['amount_tax']
        tax.is_a?(Integer) && tax >= 0 && @session['amount_total'] == @saved['amount'] + tax
      end

      def matching_event?
        return false unless exact?(@event, 'object' => 'event', 'type' => 'checkout.session.completed', 'livemode' => @saved['livemode'],
                                           'account' => nil)

        stamp = @event['created']
        valid = @event['id'].to_s.match?(/\Aevt_[A-Za-z0-9]+\z/) && stamp.is_a?(Integer) && stamp >= @saved['created_at'] && stamp <= @now.to_i
        valid && matching_event_session?
      end

      def matching_event_session?
        initial = @event.dig('data', 'object')
        values = @session.slice('id', 'mode', 'payment_status', 'customer', 'payment_intent', 'client_reference_id', 'livemode')
        exact?(initial, values) && PackIdentity.metadata_matches?(initial, @saved, @account_id)
      end

      def matching_payment?
        return false unless @session['payment_intent'].to_s.match?(/\Api_[A-Za-z0-9]+\z/)

        total = @session.fetch('amount_total')
        expected = { 'id' => @session['payment_intent'], 'status' => 'succeeded', 'capture_method' => 'automatic',
                     'livemode' => @saved['livemode'], 'customer' => @saved['customer_id'], 'currency' => 'jpy',
                     'amount' => total, 'amount_received' => total, 'application_fee_amount' => nil, 'transfer_data' => nil, 'on_behalf_of' => nil }
        exact?(@payment, expected) && PackIdentity.metadata_matches?(@payment, @saved, @account_id) && captured_charge?
      end

      def captured_charge?
        expected = { 'payment_intent' => @session['payment_intent'], 'status' => 'succeeded', 'paid' => true, 'captured' => true,
                     'refunded' => false, 'amount_refunded' => 0, 'disputed' => false, 'currency' => 'jpy', 'amount' => @session['amount_total'],
                     'amount_captured' => @session['amount_total'], 'livemode' => @saved['livemode'], 'customer' => @saved['customer_id'] }
        charge = @payment['latest_charge']
        exact?(charge, expected) && charge['id'].to_s.match?(/\Ach_[A-Za-z0-9]+\z/)
      end

      def matching_line?
        return false unless @lines.is_a?(Hash) && @lines['has_more'] == false && @lines['data'].is_a?(Array) && @lines['data'].length == 1

        line = @lines['data'].first
        expected = { 'quantity' => 1, 'currency' => 'jpy', 'amount_subtotal' => @saved['amount'], 'amount_discount' => 0 }
        exact?(line, expected) && line.dig('price', 'id') == @saved['price_id']
      end
    end
  end
end
