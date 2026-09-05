# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module AgentLogin
    module RedisStore
      module_function

      def set(key, value, not_exists:, expires_in:)
        Redis::Alfred.set(key, value, nx: not_exists, ex: expires_in)
      end
    end
  end
end
