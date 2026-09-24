# frozen_string_literal: true

require_relative 'renewal_provider_pages'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # Every page and every open payment must be accounted for. An open invoice
    # alone says nothing about whether its payment is currently processing.
    class RenewalPayments
      class Unresolved < StandardError; end
      SAFE = %w[requires_payment_method canceled].freeze

      def initialize(client, invoice)
        @client = client
        @invoice = invoice
      end

      def idle?
        each_page do |payment|
          verify_payment!(payment)
          return false if payment['status'] == 'paid'
          next if payment['status'] == 'canceled'
          return false unless payment.dig('payment', 'type') == 'payment_intent'

          return false unless idle_intent?(payment.dig('payment', 'payment_intent'))
        end
        # Older API versions expose a default intent directly on the invoice.
        id = @invoice['payment_intent']
        !id || idle_intent?(id.is_a?(Hash) ? id['id'] : id)
      end

      private

      def each_page(&)
        pages = RenewalProviderPages.new(prefix: 'inpay_') do |cursor|
          @client.list_invoice_payments(@invoice.fetch('id'), starting_after: cursor)
        end
        pages.each(&)
      end

      def verify_payment!(payment)
        raise Unresolved unless payment['invoice'] == @invoice['id'] && payment['livemode'] == @invoice['livemode'] &&
                                payment['currency'] == 'jpy' && %w[open paid canceled].include?(payment['status'])
      end

      def matching_intent?(intent, id)
        intent.is_a?(Hash) && intent['id'] == id && intent['customer'] == @invoice['customer'] &&
          intent['livemode'] == @invoice['livemode'] && intent['currency'] == 'jpy'
      end

      def idle_intent?(id)
        raise Unresolved unless id.is_a?(String) && id.match?(/\Api_[A-Za-z0-9]+\z/)

        intent = @client.retrieve_payment_intent(id)
        raise Unresolved unless matching_intent?(intent, id)

        SAFE.include?(intent['status']) && intent['amount_received'].is_a?(Integer) && intent['amount_received'].zero?
      end
    end
  end
end
