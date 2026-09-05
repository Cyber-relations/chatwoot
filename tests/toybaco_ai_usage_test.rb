# frozen_string_literal: true

require 'minitest/autorun'
require 'monitor'
require_relative '../overlay/app/lib/toybaco/ai_usage'

class ToybacoAiUsageTest < Minitest::Test
  class Record
    attr_accessor :internal_attributes, :content_attributes, :status
    def initialize(attrs = {})
      @internal_attributes = attrs
      @content_attributes = { 'other' => 'preserved' }
      @status = 'active'
      @lock = Monitor.new
    end
    def with_lock(&block) = @lock.synchronize(&block)
    def update!(attrs) = attrs.each { |key, value| public_send("#{key}=", value) }
    def active? = status == 'active'
  end

  def setup
    @now = Time.iso8601('2026-09-30T23:59:00+09:00')
    contract = Toybaco::Entitlements.snapshot_for(Toybaco::PlanCatalog.default.sale('pro', 'month'), cycle: 'month')
    contract['entitlements']['limits']['ai_replies'] = 2
    @account = Record.new('toybaco_contract' => contract, 'other' => 'preserved')
    @message = Record.new
  end

  def usage(now = @now) = Toybaco::AiUsage.new(@account, now: now)

  def test_successful_generation_consumes_one_and_deduplicates_across_months
    reserved = usage.reserve(@message)
    assert_equal 'reserved', reserved['result']
    assert_equal 1, reserved['remaining']
    assert_equal 'consumed', usage.settle(@message, token: reserved['token'], outcome: 'consumed')['result']
    assert_equal 1, usage.summary['used']
    assert_equal 'duplicate', usage.reserve(@message)['result']
    assert_equal 'duplicate', usage(@now + 120).reserve(@message)['result']
    assert_equal 0, usage(@now + 120).summary['used']
    assert_equal 'preserved', @message.content_attributes['other']
    assert_equal 'preserved', @account.internal_attributes['other']
  end

  def test_failed_generation_releases_without_consumption_and_is_not_replayed
    reserved = usage.reserve(@message)
    usage.settle(@message, token: reserved['token'], outcome: 'released')
    assert_equal 0, usage.summary['used']
    assert_equal 0, usage.summary['reserved']
    assert_equal 2, usage.summary['remaining']
    assert_equal 'duplicate', usage.reserve(@message)['result']
  end

  def test_concurrent_requests_cannot_reserve_more_than_remaining_quota
    replies = Queue.new
    threads = 8.times.map { Thread.new { replies << usage.reserve(Record.new)['result'] } }
    threads.each(&:join)
    results = Array.new(8) { replies.pop }
    assert_equal 2, results.count('reserved')
    assert_equal 6, results.count('denied')
    assert_equal 0, usage.summary['remaining']
  end

  def test_same_message_concurrently_is_reserved_once
    replies = Queue.new
    threads = 5.times.map { Thread.new { replies << usage.reserve(@message)['result'] } }
    threads.each(&:join)
    results = Array.new(5) { replies.pop }
    assert_equal 1, results.count('reserved')
    assert_equal 4, results.count('duplicate')
  end

  def test_expired_generation_cannot_deliver_or_consume
    reserved = usage.reserve(@message)
    late = usage(@now + 301)
    assert_equal 'expired_reservation', late.settle(@message, token: reserved['token'], outcome: 'consumed')['reason']
    assert_equal 0, late.summary['used']
    assert_equal 0, late.summary['reserved']
  end

  def test_reservation_crossing_jst_month_boundary_charges_its_original_month
    reserved = usage.reserve(@message)
    next_month = usage(@now + 120)
    assert_equal 'consumed', next_month.settle(@message, token: reserved['token'], outcome: 'consumed')['result']
    assert_equal 0, next_month.summary['used']
    assert_equal 1, @account.internal_attributes.dig('toybaco_ai_usage', 'periods', '2026-09', 'used')
    assert_equal '2026-11-01T00:00:00+09:00', next_month.summary['resets_at']
  end

  def test_downgrade_or_suspension_during_generation_prevents_consumption
    reserved = usage.reserve(@message)
    @account.status = 'suspended'
    assert_equal 'access_changed', usage.settle(@message, token: reserved['token'], outcome: 'consumed')['reason']
    assert_equal 0, usage.summary['used']
  end

  def test_unknown_legacy_or_disabled_plan_never_receives_an_invented_allowance
    [{}, { 'toybaco_plan' => 'standard' }, { 'toybaco_contract' => Toybaco::Entitlements.snapshot_for(
      Toybaco::PlanCatalog.default.sale('light', 'month'), cycle: 'month'
    ) }].each do |attrs|
      @account.internal_attributes = attrs
      assert_equal 'denied', usage.reserve(Record.new)['result']
      refute usage.summary['enabled']
    end
  end

  def test_wrong_token_and_other_account_cannot_consume_reservation
    reserved = usage.reserve(@message)
    assert_equal 'denied', usage.settle(@message, token: '0' * 48, outcome: 'consumed')['result']
    other = Record.new(@account.internal_attributes.reject { |key, _| key == 'toybaco_ai_usage' })
    assert_equal 'denied', Toybaco::AiUsage.new(other, now: @now).settle(@message, token: reserved['token'], outcome: 'consumed')['result']
    assert_equal 0, usage.summary['used']
  end
end
