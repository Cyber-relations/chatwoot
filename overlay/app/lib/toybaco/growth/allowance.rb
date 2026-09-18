# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    module Allowance
      GRACE_SECONDS = 7 * 24 * 60 * 60

      module_function

      def upgrade(old_limit:, new_limit:, granted:, period_seconds:, remaining_seconds:)
        values = [old_limit, new_limit, granted, period_seconds, remaining_seconds]
        raise ArgumentError, 'invalid allowance' unless non_negative_integers?(values)
        raise ArgumentError, 'invalid upgrade period' unless period_seconds.positive? && remaining_seconds <= period_seconds
        raise ArgumentError, 'not an upgrade' unless new_limit > old_limit && granted <= new_limit

        difference = Rational((new_limit - old_limit) * remaining_seconds, period_seconds).ceil
        [difference, new_limit - granted].min
      end

      def non_negative_integers?(values)
        values.all? { |value| value.is_a?(Integer) && value >= 0 }
      end

      def grace(limit:, period_seconds:)
        unless limit.is_a?(Integer) && limit >= 0 && period_seconds.is_a?(Integer) && period_seconds.positive?
          raise ArgumentError,
                'invalid allowance'
        end

        [Rational(limit * GRACE_SECONDS, period_seconds).ceil, limit].min
      end
    end
  end
end
