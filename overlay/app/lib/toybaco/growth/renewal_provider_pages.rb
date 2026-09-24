# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class RenewalProviderPages
      class Unresolved < StandardError; end
      BOOLEANS = [true, false].freeze

      def initialize(prefix:, &fetch)
        @pattern = /\A#{Regexp.escape(prefix)}[A-Za-z0-9]+\z/
        @fetch = fetch
      end

      def each
        cursor = nil
        seen = {}
        loop do
          page = @fetch.call(cursor)
          validate_page!(page)
          page['data'].each do |row|
            validate_row!(row, seen)
            yield row
          end
          break unless page['has_more']

          raise Unresolved if page['data'].empty? || seen.size >= 10_000

          cursor = page['data'].last.fetch('id')
        end
      end

      private

      def validate_page!(page)
        raise Unresolved unless page.is_a?(Hash) && page['data'].is_a?(Array) && BOOLEANS.include?(page['has_more'])
      end

      def validate_row!(row, seen)
        id = row.is_a?(Hash) && row['id']
        raise Unresolved unless id.is_a?(String) && id.match?(@pattern) && !seen[id]

        seen[id] = true
      end
    end
  end
end
