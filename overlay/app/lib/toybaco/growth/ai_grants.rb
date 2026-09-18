# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # Call only after a verified registration/payment/trial-start event. This
    # class exposes no user endpoint and never infers payment from a browser URL.
    class AiGrants
      FIELDS = %i[source source_key units starts_at ends_at].freeze

      class Conflict < StandardError; end

      def initialize(account)
        @account = account
      end

      def issue!(attributes)
        attributes = normalize(attributes)
        @account.with_lock do
          grants = Toybaco::GrowthAiGrant.where(account_id: @account.id)
          previous = grants.find_by(attributes.slice(:source, :source_key))
          return existing!(previous, attributes) if previous

          grants.create!(attributes)
        end
      end

      private

      def normalize(attributes)
        raise ArgumentError, 'invalid grant fields' unless attributes.keys.sort == FIELDS.sort

        validate_values!(attributes)

        attributes = attributes.dup
        %i[starts_at ends_at].each { |key| attributes[key] = Time.at(attributes[key].to_i, attributes[key].usec).utc }
        raise ArgumentError, 'invalid grant period' unless attributes[:ends_at] > attributes[:starts_at]

        attributes
      end

      def validate_values!(attributes)
        raise ArgumentError, 'invalid grant amount' unless attributes[:units].is_a?(Integer) && attributes[:units] >= 0
        raise ArgumentError, 'invalid grant period' unless attributes[:starts_at].is_a?(Time) && attributes[:ends_at].is_a?(Time)
      end

      def existing!(grant, attributes)
        matches = attributes.all? { |key, value| grant.public_send(key) == value }
        raise Conflict, 'grant event conflicts with its original terms' unless matches

        grant
      end
    end
  end
end
