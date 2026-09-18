# frozen_string_literal: true

require 'rails/test_help'
require 'factory_bot_rails'
require 'timeout'
require Rails.root.join('lib/toybaco/growth/ai_ledger')
require Rails.root.join('lib/toybaco/growth/ai_grants')

FactoryBot.find_definitions unless FactoryBot.factories.registered?(:account)

class ToybacoGrowthLedgerRuntimeTest < ActiveSupport::TestCase
  include FactoryBot::Syntax::Methods
  self.use_transactional_tests = true
  Ledger = Toybaco::Growth::AiLedger
  Grants = Toybaco::Growth::AiGrants
  NOW = Time.utc(2026, 9, 18, 13)

  def setup
    @account = create(:account)
    set_plan('standard')
    @ledger = Ledger.new(@account, now: NOW)
  end

  def set_plan(id)
    terms = Toybaco::PlanCatalog.default.definition(id, '2026-09-18.1')
    contract = Toybaco::Entitlements.snapshot_for(terms, cycle: id == 'free' ? nil : 'month')
    Toybaco::Entitlements.apply!(@account, contract)
  end

  def grant(source = 'included', units: 1, key: nil, ends_at: NOW + 86400)
    Grants.new(@account).issue!(source: source, source_key: key || SecureRandom.hex(12), units: units, starts_at: NOW - 60, ends_at: ends_at)
  end

  def reserve(kind = 'reply_draft', key: SecureRandom.hex(16), ledger: @ledger)
    ledger.reserve(request_key: key, kind: kind, context_digest: 'a' * 64)
  end

  def consume(reservation, ledger: @ledger, &block)
    ledger.settle(operation_id: reservation.fetch('operation_id'), token: reservation.fetch('token'), outcome: 'consumed', &(block || -> { 'draft:fixture' }))
  end

  def test_reply_post_and_automation_share_the_last_remaining_unit
    grant
    reply = reserve
    assert_equal 'reserved', reply['result']
    assert_equal 'denied', reserve('post_draft')['result']
    assert_equal 'denied', reserve('automatic_reply')['result']
    consume(reply)
    assert_equal 0, @ledger.summary['remaining']
  end

  def activate_free(anchor)
    set_plan('free')
    @account.update!(internal_attributes: @account.internal_attributes.merge(
      'toybaco_growth_registration' => { 'phase' => 'active', 'free_anchor' => anchor.iso8601 }
    ))
  end

  def test_free_refresh_uses_original_anchor_and_never_restores_consumed_units
    activate_free(Time.utc(2026, 8, 31, 12))
    assert_equal 20, @ledger.summary['remaining']
    consume(reserve)
    2.times { assert_equal 19, @ledger.summary['remaining'] }
    september = Ledger.new(@account, now: Time.utc(2026, 9, 30, 12))
    assert_equal 20, september.summary['remaining']
    october = Ledger.new(@account, now: Time.utc(2026, 10, 30, 12))
    assert_equal 20, october.summary['remaining']
    buckets = Toybaco::GrowthAiGrant.where(account_id: @account.id).order(:starts_at)
    assert_equal 2, buckets.count
    assert_equal Time.utc(2026, 10, 31, 12), buckets.last.ends_at
    assert_equal 1, buckets.first.used
  end

  def test_suspended_free_store_cannot_renew_or_generate
    activate_free(NOW - 60)
    @account.update!(status: :suspended)
    assert_equal 0, @ledger.summary['remaining']
    assert_equal 'denied', reserve['result']
    assert_empty Toybaco::GrowthAiGrant.where(account_id: @account.id)
  end

  def test_paid_store_cannot_reuse_its_old_free_anchor
    activate_free(NOW - 60)
    set_plan('standard')
    assert_equal 0, @ledger.summary['remaining']
    assert_empty Toybaco::GrowthAiGrant.where(account_id: @account.id)
  end

  def test_included_usage_precedes_earliest_expiring_pack
    later = grant('pack', ends_at: NOW + 10 * 86400)
    earlier = grant('pack', ends_at: NOW + 5 * 86400)
    included = grant('included', ends_at: NOW + 20 * 86400)
    consume(reserve)
    assert_equal 1, included.reload.used
    consume(reserve)
    assert_equal 1, earlier.reload.used
    assert_equal 0, later.reload.used
  end

  def test_repeated_payment_cannot_issue_a_second_pack_or_change_its_expiry
    first = grant('pack', units: 500, key: 'pi-fixture')
    assert_equal first.id, grant('pack', units: 500, key: 'pi-fixture').id
    assert_raises(Grants::Conflict) { grant('pack', units: 500, key: 'pi-fixture', ends_at: NOW + 2 * 86400) }
    assert_equal 1, Toybaco::GrowthAiGrant.where(account_id: @account.id).count
  end

  def test_repeated_request_and_settlement_never_charge_twice
    bucket = grant(units: 2)
    key = SecureRandom.hex(16)
    reservation = reserve(key: key)
    assert_equal 'reserved', reserve(key: key)['state']
    assert_raises(Ledger::Conflict) { reserve('post_draft', key: key) }
    consume(reservation)
    assert_equal 'consumed', consume(reservation)['state']
    assert_equal 1, bucket.reload.used
  end

  def test_failed_generation_releases_quota_and_expired_lease_cannot_publish
    bucket = grant
    reservation = reserve
    @ledger.settle(operation_id: reservation['operation_id'], token: reservation['token'], outcome: 'released')
    key = SecureRandom.hex(16)
    next_reservation = reserve(key: key)
    later = Ledger.new(@account, now: NOW + 301)
    assert_equal 'expired', reserve(key: key, ledger: later)['state']
    published = false
    consume(next_reservation, ledger: later) { published = true; 'draft:never' }
    refute published
    assert_equal 0, bucket.reload.used
    assert_equal 1, later.summary['remaining']
  end

  def test_another_store_cannot_settle_an_operation_even_with_its_token
    bucket = grant
    reservation = reserve
    other = create(:account)
    result = consume(reservation, ledger: Ledger.new(other, now: NOW))
    assert_equal 'invalid_reservation', result['reason']
    assert_equal 0, bucket.reload.used
  end

  def test_downgrade_retains_pack_drafts_but_revokes_automatic_reply
    grant('pack', units: 2)
    automatic = reserve('automatic_reply')
    set_plan('free')
    assert_equal 'released', consume(automatic)['result']
    assert_equal 'denied', reserve('automatic_reply')['result']
    assert_equal 'consumed', consume(reserve)['result']
    assert_equal 1, @ledger.summary['remaining']
  end

  def test_trial_uses_its_own_bucket_and_cannot_continue_after_expiry
    set_plan('free')
    included = grant(units: 20)
    grant('trial', units: 100, key: 'one-time-auto-reply', ends_at: NOW + 60)
    reservation = reserve('automatic_reply')
    assert_equal 20, @ledger.summary['remaining']
    assert_equal 'released', consume(reservation, ledger: Ledger.new(@account, now: NOW + 60))['result']
    assert_equal 0, included.reload.used
  end

  def test_persisting_the_generated_result_and_charging_are_one_transaction
    bucket = grant
    reservation = reserve
    count = Contact.where(account_id: @account.id).count
    assert_raises(RuntimeError) do
      consume(reservation) do
        create(:contact, account: @account)
        raise 'fixture persistence failure'
      end
    end
    assert_equal count, Contact.where(account_id: @account.id).count
    assert_equal 0, bucket.reload.used
    assert_equal 'reserved', Toybaco::GrowthAiOperation.find(reservation['operation_id']).state
  end

  def test_in_flight_generation_uses_the_reserved_month_and_support_never_consumes
    bucket = grant(ends_at: NOW + 1)
    reservation = reserve
    assert_equal 'consumed', consume(reservation, ledger: Ledger.new(@account, now: NOW + 2))['result']
    assert_equal 1, bucket.reload.used
    assert_raises(ArgumentError) { reserve('support') }
  end
end

# Separate committed fixtures let independent DB connections race for one unit.
# Only records created by this test are removed.
class ToybacoGrowthLedgerConcurrencyTest < ActiveSupport::TestCase
  include FactoryBot::Syntax::Methods
  self.use_transactional_tests = false

  def test_concurrent_post_and_reply_cannot_overspend_one_store
    account = create(:account)
    terms = Toybaco::PlanCatalog.default.definition('standard', '2026-09-18.1')
    Toybaco::Entitlements.apply!(account, Toybaco::Entitlements.snapshot_for(terms, cycle: 'month'))
    now = Time.now.utc
    grant = Toybaco::Growth::AiGrants.new(account).issue!(source: 'included', source_key: SecureRandom.hex(12), units: 1,
                                                        starts_at: now - 1, ends_at: now + 3600)
    ready = Queue.new
    start = Queue.new
    workers = %w[reply_draft post_draft].map do |kind|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          Toybaco::Growth::AiLedger.new(Account.find(account.id), now: now).reserve(
            request_key: SecureRandom.hex(16), kind: kind, context_digest: 'b' * 64
          )
        end
      end
    end
    Timeout.timeout(20) { 2.times { ready.pop } }
    2.times { start << true }
    results = Timeout.timeout(20) { workers.map(&:value) }
    assert_equal %w[denied reserved], results.map { |value| value.fetch('result') }.sort
    assert_equal 1, grant.operations.where(state: 'reserved').count
    assert_equal 0, grant.reload.used
  ensure
    workers&.each { start << true }
    workers&.each { |worker| worker.join(5) || worker.kill.join }
    account&.destroy!
  end
end
