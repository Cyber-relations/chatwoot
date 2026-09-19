# frozen_string_literal: true

require 'digest'
require_relative 'payment_snapshot'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    module PaymentReceipt
      class Conflict < StandardError; end
      module_function

      def accept!(attributes, now: Time.now.utc)
        return unless attributes

        digest = Digest::SHA256.hexdigest(JSON.generate(attributes.fetch(:snapshot)))
        event = Toybaco::GrowthPaymentEvent.create_or_find_by!(event_id: attributes.fetch(:event_id)) do |record|
          record.assign_attributes(attributes.merge(payload_digest: digest, next_attempt_at: now))
        end
        raise Conflict unless event.payload_digest == digest && event.snapshot == attributes.fetch(:snapshot)

        event
      end
    end
  end
end
