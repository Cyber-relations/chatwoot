# frozen_string_literal: true

require 'securerandom'
require 'connection_pool'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Support
    class Capacity
      class Unavailable < StandardError; end

      class Limited < StandardError
        attr_reader :retry_after

        def initialize(retry_after)
          @retry_after = retry_after
          super('support temporarily limited')
        end
      end

      RESERVE = <<~LUA
        local now = tonumber(redis.call('TIME')[1])
        local windows = {600, 3600, 65}
        local limits = {20, 100, 3}
        local wait = 0
        for i=1,3 do
          redis.call('ZREMRANGEBYSCORE', KEYS[i], '-inf', now-windows[i])
          if redis.call('ZCARD', KEYS[i]) >= limits[i] then
            local first = redis.call('ZRANGE', KEYS[i], 0, 0, 'WITHSCORES')
            wait = math.max(wait, tonumber(first[2])+windows[i]-now)
          end
        end
        if wait > 0 then return {0, wait} end
        for i=1,3 do
          redis.call('ZADD', KEYS[i], now, ARGV[1])
          redis.call('EXPIRE', KEYS[i], windows[i]+1)
        end
        return {1,0}
      LUA

      def initialize(account_id, user_id, store: Redis::Alfred)
        @store = store
        prefix = 'TOYBACO_SUPPORT::{limits}'
        @keys = ["#{prefix}:user:#{user_id}", "#{prefix}:account:#{account_id}", "#{prefix}:running:#{account_id}"]
      end

      def within
        token = reserve!
        yield
      ensure
        release(token) if token
      end

      private

      def reserve!
        token = SecureRandom.hex(24)
        result = @store.with { |connection| connection.eval(RESERVE, keys: @keys, argv: [token]) }
        raise Unavailable unless result.is_a?(Array) && result.length == 2
        raise Limited, result[1] if limited?(result)
        raise Unavailable unless result == [1, 0]

        token
      rescue Redis::BaseError, ConnectionPool::TimeoutError, IOError, TypeError, ArgumentError
        raise Unavailable
      end

      def limited?(result)
        result[0].is_a?(Integer) && result[0].zero? && result[1].is_a?(Integer) && result[1].between?(1, 3600)
      end

      def release(token)
        @store.with { |connection| connection.zrem(@keys.last, token) }
      rescue Redis::BaseError, ConnectionPool::TimeoutError, IOError
        # The 65 second lease expires without extending another request's lease.
        nil
      end
    end
  end
end
