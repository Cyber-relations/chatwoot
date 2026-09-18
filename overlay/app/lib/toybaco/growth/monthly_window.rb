# frozen_string_literal: true

require 'date'
require 'time'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # Recompute each boundary from the ORIGINAL anchor. February's clamp must
    # not turn a January 31 contract into a permanent February 28 anchor.
    class MonthlyWindow
      def initialize(anchor:, now: Time.now.utc, ends_at: nil)
        @anchor = anchor.utc
        @now = now.utc
        @ends_at = ends_at&.utc
      end

      def current
        return if @now < @anchor || (@ends_at && @now >= @ends_at)

        index = ((@now.year - @anchor.year) * 12) + @now.month - @anchor.month
        index -= 1 if boundary(index) > @now
        starts_at = boundary(index)
        ends_at = boundary(index + 1)
        ends_at = [ends_at, @ends_at].min if @ends_at
        { 'starts_at' => starts_at.to_i, 'ends_at' => ends_at.to_i }
      end

      private

      def boundary(index)
        year, month = ((@anchor.year * 12) + @anchor.month - 1 + index).divmod(12)
        month += 1
        day = [@anchor.day, Date.new(year, month, -1).day].min
        Time.utc(year, month, day, @anchor.hour, @anchor.min, @anchor.sec)
      end
    end
  end
end
