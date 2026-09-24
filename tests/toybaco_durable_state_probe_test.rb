# frozen_string_literal: true

require 'minitest/autorun'
require 'pg'
require 'json'
require 'digest'
require ENV.fetch('TOYBACO_DURABLE_PROBE_SOURCE', '/app/bin/toybaco-durable-state-probe.rb')

class ToybacoDurableStateProbeTest < Minitest::Test
  def setup
    @db = PG.connect(ENV.fetch('TOYBACO_DURABLE_PROBE_TEST_DATABASE_URL'))
    raise 'dedicated fixture database required' unless @db.db == 'toybaco_durable_probe_fixture'

    @db.exec("SET client_min_messages = 'warning'")
    @other = PG.connect(ENV.fetch('TOYBACO_DURABLE_PROBE_TEST_DATABASE_URL'))
    @db.exec('DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public')
    @db.exec('CREATE TABLE schema_migrations (version text PRIMARY KEY)')
    @db.exec("INSERT INTO schema_migrations VALUES ('20260924040000')")
    @db.exec('CREATE TABLE accounts (id bigint PRIMARY KEY, internal_attributes jsonb NOT NULL)')
    @db.exec('CREATE TABLE toybaco_billing_events (id bigint PRIMARY KEY, state text NOT NULL)')
    @db.exec('CREATE TABLE toybaco_subscription_sync_requests (id bigint PRIMARY KEY, state text NOT NULL)')
    @manifest = { 'version' => 1, 'application' => 'chatwoot', 'capabilities' => {
      'billing-ingress-v1' => { 'schema_sha256' => schema, 'tables' => ['toybaco_billing_events'] },
      'subscription-reconciliation-v1' => { 'schema_sha256' => schema, 'tables' => ['toybaco_subscription_sync_requests'],
                                          'account_keys' => ['toybaco_growth_inbox_retention'] }
    } }
  end

  def teardown
    @other&.close
    @db&.close
  end

  def schema
    Digest::SHA256.hexdigest("20260924040000\n")
  end

  def read
    ToybacoDurableStateProbe.new(@db, @manifest).read('b' * 32)
  end

  def test_empty_schema_has_no_required_capability_and_returns_no_business_data
    value = read
    assert_equal({ 'billing-ingress-v1' => false, 'subscription-reconciliation-v1' => false }, value.fetch('markers'))
    assert_equal %w[application markers nonce schema_sha256 version], value.keys.sort
    assert_equal schema, value.fetch('schema_sha256')
    assert_equal PG::PQTRANS_IDLE, @db.transaction_status
  end

  def test_every_terminal_or_uncertain_state_is_a_marker
    %w[pending processing uncertain completed attention].each do |state|
      @db.exec_params('INSERT INTO toybaco_billing_events VALUES (1, $1)', [state])
      assert read.fetch('markers').fetch('billing-ingress-v1')
      @db.exec('DELETE FROM toybaco_billing_events')
    end
  end

  def test_flag_off_does_not_remove_accepted_marker
    @db.exec("INSERT INTO toybaco_billing_events VALUES (1, 'completed')")
    previous = ENV['TOYBACO_BILLING_INGRESS_ENABLED']
    ENV['TOYBACO_BILLING_INGRESS_ENABLED'] = 'false'
    assert read.fetch('markers').fetch('billing-ingress-v1')
  ensure
    ENV['TOYBACO_BILLING_INGRESS_ENABLED'] = previous
  end

  def test_account_json_receipt_is_retained_even_when_corrupt_or_null
    ['null', '{}', '{"state":"released"}'].each do |value|
      @db.exec_params("INSERT INTO accounts VALUES (1, jsonb_build_object('toybaco_growth_inbox_retention', $1::jsonb))", [value])
      assert read.fetch('markers').fetch('subscription-reconciliation-v1')
      @db.exec('DELETE FROM accounts')
    end
  end

  def test_fresh_second_connection_commit_is_visible
    refute read.fetch('markers').fetch('billing-ingress-v1')
    @other.exec("INSERT INTO toybaco_billing_events VALUES (1, 'pending')")
    assert read.fetch('markers').fetch('billing-ingress-v1')
  end

  def test_outer_old_snapshot_is_rejected_without_rolling_back_caller
    @db.exec('BEGIN ISOLATION LEVEL REPEATABLE READ')
    assert_raises(ToybacoDurableStateProbe::Denied) { read }
    assert_equal PG::PQTRANS_INTRANS, @db.transaction_status
  ensure
    @db.exec('ROLLBACK')
  end

  def test_schema_mismatch_and_missing_table_fail_closed
    @db.exec("INSERT INTO schema_migrations VALUES ('20260924050000')")
    assert_raises(ToybacoDurableStateProbe::Denied) { read }
    @db.exec("DELETE FROM schema_migrations WHERE version='20260924050000'; DROP TABLE toybaco_subscription_sync_requests")
    @db.exec("INSERT INTO toybaco_billing_events VALUES (1, 'completed')")
    assert_raises(ToybacoDurableStateProbe::Denied) { read }
  end

  def test_undeclared_future_feature_table_is_not_ignored
    %w[toybaco_growth_auto_installations toybaco_growth_renewal_settlements toybaco_growth_scheduled_grant_upgrades
       toybaco_growth_renewal_dispatches].each do |table|
      @db.exec("CREATE TABLE #{table} (id bigint)")
      assert_raises(ToybacoDurableStateProbe::Denied) { read }
      @db.exec("DROP TABLE #{table}")
    end
  end

  def test_row_security_cannot_hide_a_marker
    @db.exec('ALTER TABLE toybaco_billing_events ENABLE ROW LEVEL SECURITY')
    assert_raises(ToybacoDurableStateProbe::Denied) { read }
  end

  def test_account_row_security_cannot_hide_json_marker
    @db.exec('ALTER TABLE accounts ENABLE ROW LEVEL SECURITY')
    assert_raises(ToybacoDurableStateProbe::Denied) { read }
  end

  def test_unadvertised_v3_and_unknown_execution_versions_fail_closed
    @db.exec('CREATE TABLE toybaco_growth_posting_executions (id bigint, request jsonb)')
    @db.exec(%q(INSERT INTO toybaco_growth_posting_executions VALUES (1, '{"version":2}')))
    refute read.fetch('markers').fetch('billing-ingress-v1')
    @db.exec(%q(UPDATE toybaco_growth_posting_executions SET request='{"version":3}'))
    assert_raises(ToybacoDurableStateProbe::Denied) { read }
    @db.exec(%q(UPDATE toybaco_growth_posting_executions SET request='{"version":4}'))
    assert_raises(ToybacoDurableStateProbe::Denied) { read }
  end

  def test_completed_v3_is_a_marker_even_when_authority_pointers_are_empty
    tables = %w[toybaco_growth_posting_authorities toybaco_growth_posting_authority_currents]
    tables.each { |table| @db.exec("CREATE TABLE #{table} (id bigint)") }
    @db.exec('CREATE TABLE toybaco_growth_posting_executions (id bigint, state text, request jsonb)')
    @manifest.fetch('capabilities')['posting-authority-v1'] = { 'schema_sha256' => schema, 'tables' => tables }
    @db.exec(%q(INSERT INTO toybaco_growth_posting_executions VALUES (1, 'completed', '{"version":2}')))
    refute read.fetch('markers').fetch('posting-authority-v1')
    @db.exec(%q(UPDATE toybaco_growth_posting_executions SET request='{"version":3}'))
    assert read.fetch('markers').fetch('posting-authority-v1')
  end

  def test_probe_transaction_is_read_only
    wrapper = Object.new
    target = @db
    wrapper.define_singleton_method(:method_missing) do |name, *args|
      if name == :exec && args.first == 'COMMIT'
        target.exec("INSERT INTO toybaco_billing_events VALUES (99,'fixture')")
      end
      target.public_send(name, *args)
    end
    assert_raises(PG::ReadOnlySqlTransaction) { ToybacoDurableStateProbe.new(wrapper, @manifest).read('b' * 32) }
    assert_equal '0', @db.exec('SELECT count(*) FROM toybaco_billing_events').first.values.first
  end
end
