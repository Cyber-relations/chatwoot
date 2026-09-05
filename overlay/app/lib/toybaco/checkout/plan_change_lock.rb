# frozen_string_literal: true

require 'digest'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Checkout
    # A session lock serializes billing commands without holding a database
    # transaction over HTTP. Each receipt write commits before its Stripe call.
    module PlanChangeLock
      module_function

      def call(account)
        unsigned = Digest::SHA256.hexdigest("toybaco-plan-change:#{Integer(account.id)}")[0, 16].to_i(16)
        key = unsigned >= 2**63 ? unsigned - (2**64) : unsigned
        account.class.connection_pool.with_connection do |connection|
          acquired = connection.select_value("SELECT pg_try_advisory_lock(#{key})")
          raise PlanChangeError, 'busy' unless acquired

          begin
            account.reload
            yield
          ensure
            connection.select_value("SELECT pg_advisory_unlock(#{key})")
          end
        end
      end
    end
  end
end
