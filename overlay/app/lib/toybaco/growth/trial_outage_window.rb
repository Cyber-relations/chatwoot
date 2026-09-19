# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # Pause the original trial clock across the union of confirmed intervals.
    # Sorting/merging makes overlapping reports and arrival order equivalent.
    module TrialOutageWindow
      module_function

      def deadline(starts_at:, base_ends_at:, intervals:)
        ending = merged(intervals).reduce(base_ends_at) do |deadline, (first, last)|
          first = [first, starts_at].max
          first < deadline && last > first ? deadline + (last - first) : deadline
        end
        base_ends_at + (ending.to_r - base_ends_at.to_r).ceil
      end

      def merged(intervals)
        intervals.sort_by(&:first).each_with_object([]) do |interval, result|
          if result.last && interval.first <= result.last.last
            result.last[1] = [result.last.last, interval.last].max
          else
            result << interval.dup
          end
        end
      end
    end
  end
end
