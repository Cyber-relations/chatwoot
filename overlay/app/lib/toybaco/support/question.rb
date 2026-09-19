# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Support
    module Question
      class Invalid < StandardError; end
      class PrivateData < StandardError; end
      PRIVATE = %r{https?://|[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}|[A-Za-z0-9_+/=.-]{24,}|\d[\d\ -]{8,}\d|-----BEGIN|
                   (?:password|secret|token|パスワード|秘密鍵|トークン)\s*[:：=]}ix

      module_function

      def read(value)
        raise Invalid unless valid?(value)
        raise PrivateData if value.match?(PRIVATE)

        value.strip
      end

      def valid?(value)
        return false unless value.is_a?(String) && value.valid_encoding? && value.length <= 500 && value.bytesize <= 2400

        !value.strip.empty? && !value.match?(/[\x00-\x08\x0b\x0c\x0e-\x1f]/)
      end
    end
  end
end
