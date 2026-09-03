# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  # /api の data_services は upstream が ActiveRecord::Base.connection.active? だけを見る。
  # active? は stale/dead PG を false で返し、張り直さない。長寿命 worker では
  # 実体の Postgres が生きていても failing になる。宣言前に verify! し、
  # 必要なら同じ接続だけ reconnect する。本当に届かないときは failing のまま。
  module PostgresHealth
    CONNECTION_ERROR_NAMES = %w[
      ActiveRecord::ConnectionNotEstablished
      ActiveRecord::DatabaseConnectionError
      PG::Error
    ].freeze

    module ApiControllerOverride
      private

      def postgres_status
        Toybaco::PostgresHealth.verify_or_reconnect!
        'ok'
      rescue ActiveRecord::ConnectionNotEstablished
        'failing'
      end
    end

    module_function

    def verify_or_reconnect!(connection = default_connection)
      raise connection_not_established('postgres connection is missing') if connection.nil?

      with_connection_errors do
        connection.verify!
        return true if live?(connection)

        connection.reconnect! if connection.respond_to?(:reconnect!)
        return true if live?(connection)

        raise connection_not_established('stale postgres connection could not be reestablished')
      end
    end

    def install!
      return unless defined?(::ApiController)
      return if ::ApiController < ApiControllerOverride

      ::ApiController.prepend(ApiControllerOverride)
    end

    def default_connection
      return unless defined?(ActiveRecord::Base)
      return unless ActiveRecord::Base.respond_to?(:connection)

      ActiveRecord::Base.connection
    end

    def live?(connection)
      connection.respond_to?(:active?) && connection.active?
    end

    def connection_error?(error)
      error.class.ancestors.map(&:name).intersect?(CONNECTION_ERROR_NAMES)
    end

    def with_connection_errors
      yield
    rescue StandardError => e
      raise if established_error?(e)
      raise unless connection_error?(e)

      raise connection_not_established_class, e.message, e.backtrace, cause: e
    end

    def established_error?(error)
      error.class.ancestors.map(&:name).include?('ActiveRecord::ConnectionNotEstablished')
    end

    def connection_not_established_class
      if defined?(ActiveRecord::ConnectionNotEstablished)
        ActiveRecord::ConnectionNotEstablished
      else
        StandardError
      end
    end

    def connection_not_established(message)
      connection_not_established_class.new(message)
    end
  end
end
