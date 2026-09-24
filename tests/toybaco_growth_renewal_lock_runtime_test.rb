# frozen_string_literal: true

require 'rails/test_help'
require 'factory_bot_rails'
require 'timeout'
require Rails.root.join('lib/toybaco/growth/renewal_settlement')

FactoryBot.find_definitions unless FactoryBot.factories.registered?(:account)

class ToybacoGrowthRenewalLockRuntimeTest < ActiveSupport::TestCase
  include FactoryBot::Syntax::Methods
  self.use_transactional_tests = false
  Lock = Toybaco::Checkout::PlanChangeLock
  Settlement = Toybaco::Growth::RenewalSettlement
  NOW = Time.utc(2026, 10, 11, 12)

  def setup
    @account = create(:account)
    @other = create(:account)
    terms = Toybaco::PlanCatalog.default.definition('standard', '2026-09-18.1')
    contract = Toybaco::Entitlements.snapshot_for(terms, cycle: 'month')
    @account.update!(internal_attributes: {
      'toybaco_contract' => contract, 'toybaco_subscription_id' => 'sub_lock', 'toybaco_stripe_customer_id' => 'cus_lock',
      Settlement::FAILURE_KEY => { 'subscription_id' => 'sub_lock', 'invoice_id' => 'in_lock',
        'term_start' => (NOW - 8.days).to_i, 'term_end' => (NOW + 22.days).to_i,
        'first_failed_at' => (NOW - 8.days).to_i, 'grace_ends_at' => (NOW - 1.day).to_i }
    })
    @reads = []
    @client = Object.new
    reads = @reads
    @client.define_singleton_method(:retrieve_subscription) do |id|
      reads << id
      raise Toybaco::Checkout::Error, 'fixture provider unavailable'
    end
  end

  def teardown
    @account&.destroy!
    @other&.destroy!
    Current.reset
  end

  def settle
    Settlement.new(@account, client: @client, now: NOW, environment: { 'TOYBACO_STRIPE_MODE' => 'test' }).call
  end

  # Separate checked-out PostgreSQL sessions, not a Ruby mutex or a mocked lock.
  def with_remote_billing_lock(account)
    ready = Queue.new
    release = Queue.new
    worker = Thread.new do
      Account.connection_pool.with_connection do
        Lock.call(Account.find(account.id)) do
          ready << true
          release.pop
        end
      end
    rescue StandardError => e
      ready << e
      raise
    end
    signal = Timeout.timeout(5) { ready.pop }
    raise signal if signal.is_a?(Exception)

    yield
  ensure
    release << true
    if worker
      unless worker.join(5)
        worker.kill
        worker.join
        flunk 'billing lock worker failed to exit'
      end
      worker.value
    end
  end

  def test_plan_change_in_another_database_session_blocks_settlement_before_provider_read
    with_remote_billing_lock(@account) do
      assert_equal 'billing_operation_pending', settle
      assert_empty @reads
      refute @account.reload.internal_attributes.key?(Settlement::KEY)
    end
    assert_equal 'retry_required', settle
    assert_equal ['sub_lock'], @reads
  end

  def test_another_store_does_not_block_this_store
    with_remote_billing_lock(@other) do
      assert_equal 'retry_required', settle
      assert_equal ['sub_lock'], @reads
    end
  end

  def test_query_cache_never_reuses_a_billing_lock_acquisition_or_unlock
    Account.cache do
      assert_equal :first, Lock.call(@account) { :first }
      with_remote_billing_lock(@account) do
        assert_raises(Toybaco::Checkout::PlanChangeError) { Lock.call(@account) { flunk 'cached true bypassed lock' } }
      end
      assert_raises(RuntimeError) { Lock.call(@account) { raise 'fixed fixture failure' } }
      with_remote_billing_lock(@account) { assert true }
      assert_equal :again, Lock.call(@account) { :again }
      with_remote_billing_lock(@account) { assert true }
    end
  end

  def test_settlement_holds_the_plan_change_lock_through_provider_read_and_releases_after_failure
    account_id = @account.id
    observed = []
    @client.define_singleton_method(:retrieve_subscription) do |_id|
      worker = Thread.new do
        Account.connection_pool.with_connection do
          Lock.call(Account.find(account_id)) { observed << 'incorrectly_acquired' }
        end
      rescue Toybaco::Checkout::PlanChangeError => e
        observed << e.message
      end
      raise 'lock check timed out' unless worker.join(5)

      worker.value
      raise Toybaco::Checkout::Error, 'fixture provider unavailable'
    end
    assert_equal 'retry_required', settle
    assert_equal ['busy'], observed
    with_remote_billing_lock(@account) { assert true }
  end

  def test_saved_unresolved_operation_survives_and_blocks_settlement_after_lock_is_free
    receipt = { 'status' => 'requested', 'quote' => { 'operation' => 'fixture' } }
    @account.update!(internal_attributes: @account.internal_attributes.merge('toybaco_plan_change' => receipt))
    assert_equal 'billing_operation_pending', settle
    assert_empty @reads
    assert_equal receipt, @account.reload.internal_attributes['toybaco_plan_change']
  end
end
