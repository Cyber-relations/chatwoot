# frozen_string_literal: true

require 'delegate'
require_relative 'payment_signature'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # Only the authenticated ingress creates this immutable, minimal snapshot.
    # Other provider objects are always read afresh through the underlying client.
    class PaymentClient < SimpleDelegator
      def initialize(client, snapshot)
        super(client)
        @snapshot = snapshot
      end

      def retrieve_event(event_id)
        raise PaymentSignature::Invalid unless event_id == @snapshot.fetch('id')

        @snapshot.deep_dup
      end
    end
  end
end
