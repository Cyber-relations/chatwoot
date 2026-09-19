# frozen_string_literal: true

require 'rails/test_help'
require 'minitest/mock'
require Rails.root.join('lib/toybaco/support/capacity')

class ToybacoSupportCapacityRuntimeTest < ActiveSupport::TestCase
  Capacity = Toybaco::Support::Capacity

  def setup
    @account_id = SecureRandom.random_number(2**60)
    @user_id = SecureRandom.random_number(2**60)
    @keys = []
    @store = ConnectionPool.new(size: 5, timeout: 1) { Redis::Namespace.new('alfred', redis: Redis.new(url: ENV.fetch('REDIS_URL'))) }
  end

  def teardown
    @store.with { |connection| connection.del(*@keys.uniq) } if @keys.any?
    @store.shutdown(&:close)
  end

  def capacity(account = @account_id, user = @user_id)
    result = Capacity.new(account, user, store: @store)
    @keys.concat(result.instance_variable_get(:@keys))
    result
  end

  def test_three_store_slots_are_atomic_and_released_after_success_or_failure
    first, second, third, fourth = 4.times.map { |i| capacity(@account_id, @user_id + i) }
    first.within do
      second.within do
        third.within do
          error = assert_raises(Capacity::Limited) { fourth.within { flunk 'fourth model must not start' } }
          assert_operator error.retry_after, :<=, 65
        end
        assert_equal :accepted, fourth.within { :accepted }
      end
    end
    assert_raises(RuntimeError) { first.within { raise 'fixture model failed' } }
    assert_equal :accepted, first.within { second.within { third.within { :accepted } } }
  end

  def test_twenty_requests_per_user_are_counted_even_when_reusing_the_same_service_object
    selected = capacity
    20.times { selected.within { true } }
    error = assert_raises(Capacity::Limited) { capacity(@account_id + 1).within { flunk 'switching stores must not reset user rate' } }
    assert_operator error.retry_after, :>, 0
    assert_operator error.retry_after, :<=, 600
  end

  def test_one_hundred_requests_per_store_include_every_staff_member
    5.times do |i|
      selected = capacity(@account_id, @user_id + i)
      20.times { selected.within { true } }
    end
    error = assert_raises(Capacity::Limited) { capacity(@account_id, @user_id + 6).within { flunk 'store cap exceeded' } }
    assert_operator error.retry_after, :<=, 3600
    assert_operator error.retry_after, :>, 600
  end

  def test_expired_slots_recover_and_old_release_does_not_remove_a_new_lease
    selected = capacity
    keys = selected.instance_variable_get(:@keys)
    @store.with do |connection|
      now = connection.time.first.to_i
      3.times { |i| connection.zadd(keys.last, now - 66, "expired-#{i}") }
    end
    selected.within do
      @store.with { |connection| connection.zadd(keys.last, connection.time.first.to_i, 'separate-current-lease') }
    end
    assert_equal ['separate-current-lease'], @store.with { |connection| connection.zrange(keys.last, 0, -1) }
  end

  def test_rate_store_failure_stops_inference
    failing = Object.new
    def failing.with
      raise IOError, 'fixture unavailable'
    end
    assert_raises(Capacity::Unavailable) { Capacity.new(@account_id, @user_id, store: failing).within { flunk 'inference without guard' } }
    def failing.with
      raise ConnectionPool::TimeoutError, 'fixture pool exhausted'
    end
    assert_raises(Capacity::Unavailable) { Capacity.new(@account_id, @user_id, store: failing).within { flunk 'inference without capacity' } }
  end
end
