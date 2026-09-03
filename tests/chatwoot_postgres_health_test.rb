# frozen_string_literal: true

require 'minitest/autorun'

# overlay helper を Rails なしで検証する。AWS / 本番秘密は使わない。
module ActiveRecord
  class ConnectionNotEstablished < StandardError; end
  class DatabaseConnectionError < ConnectionNotEstablished; end

  class Base
    class << self
      attr_accessor :connection
    end
  end
end

module PG
  class Error < StandardError; end
  class ConnectionBad < Error; end
end

require_relative '../overlay/app/lib/toybaco/postgres_health'

class ChatwootPostgresHealthTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  HEALTH = Toybaco::PostgresHealth

  class FakeConnection
    attr_reader :verify_calls, :reconnect_calls

    def initialize(alive: false, verify_reopens: true, reconnect_reopens: true, verify_error: nil,
                   reconnect_error: nil)
      @alive = alive
      @verify_reopens = verify_reopens
      @reconnect_reopens = reconnect_reopens
      @verify_error = verify_error
      @reconnect_error = reconnect_error
      @verify_calls = 0
      @reconnect_calls = 0
    end

    def active?
      @alive
    end

    def verify!
      @verify_calls += 1
      raise @verify_error if @verify_error

      @alive = true if @verify_reopens
    end

    def reconnect!
      @reconnect_calls += 1
      raise @reconnect_error if @reconnect_error

      @alive = true if @reconnect_reopens
    end
  end

  def setup
    ActiveRecord::Base.connection = nil
  end

  def test_verify_reopens_stale_connection_without_second_reconnect
    connection = FakeConnection.new(alive: false, verify_reopens: true)

    assert HEALTH.verify_or_reconnect!(connection)
    assert_equal 1, connection.verify_calls
    assert_equal 0, connection.reconnect_calls
  end

  def test_live_connection_is_verified_but_not_reconnected
    connection = FakeConnection.new(alive: true)

    assert HEALTH.verify_or_reconnect!(connection)
    assert_equal 1, connection.verify_calls
    assert_equal 0, connection.reconnect_calls
  end

  def test_reconnects_same_connection_when_verify_leaves_it_dead
    connection = FakeConnection.new(alive: false, verify_reopens: false, reconnect_reopens: true)

    assert HEALTH.verify_or_reconnect!(connection)
    assert_equal 1, connection.verify_calls
    assert_equal 1, connection.reconnect_calls
  end

  def test_fail_closed_when_stale_connection_cannot_reopen
    connection = FakeConnection.new(alive: false, verify_reopens: false, reconnect_reopens: false)

    error = assert_raises(ActiveRecord::ConnectionNotEstablished) do
      HEALTH.verify_or_reconnect!(connection)
    end
    assert_match(/stale postgres connection/, error.message)
  end

  def test_wraps_pg_errors_as_connection_not_established
    connection = FakeConnection.new(verify_error: PG::ConnectionBad.new('server closed the connection'))

    error = assert_raises(ActiveRecord::ConnectionNotEstablished) do
      HEALTH.verify_or_reconnect!(connection)
    end
    assert_kind_of PG::ConnectionBad, error.cause
  end

  def test_does_not_swallow_unexpected_errors
    connection = FakeConnection.new(verify_error: RuntimeError.new('programmer error'))

    error = assert_raises(RuntimeError) do
      HEALTH.verify_or_reconnect!(connection)
    end
    assert_equal 'programmer error', error.message
  end

  def test_postgres_status_ok_after_verify
    ActiveRecord::Base.connection = FakeConnection.new(alive: false, verify_reopens: true)
    controller = Class.new do
      def postgres_status
        raise 'upstream active? path should not run'
      end
      prepend Toybaco::PostgresHealth::ApiControllerOverride
    end.new

    assert_equal 'ok', controller.send(:postgres_status)
  end

  def test_postgres_status_failing_when_unrecoverable
    ActiveRecord::Base.connection = FakeConnection.new(alive: false, verify_reopens: false, reconnect_reopens: false)
    controller = Class.new do
      def postgres_status
        raise 'upstream active? path should not run'
      end
      prepend Toybaco::PostgresHealth::ApiControllerOverride
    end.new

    assert_equal 'failing', controller.send(:postgres_status)
  end

  def test_install_prepends_api_controller_once
    api = Class.new
    Object.const_set(:ApiController, api)

    HEALTH.install!
    HEALTH.install!

    assert_operator api, :<, Toybaco::PostgresHealth::ApiControllerOverride
    assert_equal 1, api.ancestors.count { |mod| mod == Toybaco::PostgresHealth::ApiControllerOverride }
  ensure
    Object.send(:remove_const, :ApiController) if Object.const_defined?(:ApiController)
  end

  def test_uses_activerecord_base_connection_by_default
    connection = FakeConnection.new(alive: false, verify_reopens: true)
    ActiveRecord::Base.connection = connection

    assert HEALTH.verify_or_reconnect!
    assert_equal 1, connection.verify_calls
  end

  def test_initializer_is_thin_to_prepare_install
    initializer = File.read(File.join(ROOT, 'overlay/app/config/initializers/toybaco_postgres_health.rb'))
    lib = File.read(File.join(ROOT, 'overlay/app/lib/toybaco/postgres_health.rb'))

    assert_includes initializer, 'Rails.application.config.to_prepare'
    assert_includes initializer, 'Toybaco::PostgresHealth.install!'
    assert_includes lib, 'connection.verify!'
    assert_includes lib, 'connection.reconnect!'
    assert_includes lib, '::ApiController.prepend(ApiControllerOverride)'
    assert_includes lib, 'ActiveRecord::Base.connection'
    refute_includes lib, 'force-new-deployment'
    refute_includes lib, 'TOYBACO_E2E_STAGING_READY'
    refute_includes initializer, 'terraform'
    refute_includes initializer, 'workflow_dispatch'
    refute_match(/sk_live|rk_live|whsec_|AKIA/, lib)
    refute_match(/sk_live|rk_live|whsec_|AKIA/, initializer)
  end
end
