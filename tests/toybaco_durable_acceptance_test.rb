# frozen_string_literal: true

require 'minitest/autorun'
require 'pg'
require 'json'
require 'digest'
require 'timeout'
require ENV.fetch('TOYBACO_DURABLE_PROBE_SOURCE', '/app/bin/toybaco-durable-state-probe.rb')

class ToybacoDurableAcceptanceTest < Minitest::Test
  Definition = Toybaco::DurableAcceptance

  def setup
    @url = ENV.fetch('TOYBACO_DURABLE_PROBE_TEST_DATABASE_URL')
    @db = PG.connect(@url)
    raise 'dedicated fixture database required' unless @db.db == 'toybaco_durable_probe_fixture'

    @db.exec("SET client_min_messages = 'warning'")
    @db.exec('DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public')
    @db.exec('CREATE TABLE schema_migrations (version text PRIMARY KEY)')
    @db.exec("INSERT INTO schema_migrations VALUES ('20260924060000')")
    @db.exec("CREATE TABLE accounts (id bigint PRIMARY KEY, internal_attributes jsonb NOT NULL DEFAULT '{}')")
    Definition.bindings(Definition::SOURCES.keys).map { |_, table, _| table }.uniq.reject { |table| table == 'accounts' }.each do |table|
      @db.exec("CREATE TABLE #{table} (id bigint PRIMARY KEY, account_id bigint REFERENCES accounts(id) ON DELETE CASCADE, " \
               "action text NOT NULL DEFAULT 'subscription_sync', request jsonb NOT NULL DEFAULT '{\"version\":2}')")
    end
    @manifest = { 'version' => 1, 'application' => 'chatwoot', 'capabilities' => Definition::SOURCES.to_h do |name, sources|
      tables = sources.reject { |table, rule| table == 'accounts' || rule == 'execution_v3' }.keys + [Definition::TABLE]
      value = { 'schema_sha256' => Digest::SHA256.hexdigest("20260924060000\n"), 'tables' => tables }
      value['account_keys'] = Definition::ACCOUNT_KEYS if name == 'growth-retention-v1'
      [name, value]
    end }
  end

  def teardown
    @db.exec('ROLLBACK') if @db && @db.transaction_status != PG::PQTRANS_IDLE
    @db&.close
  end

  def install
    @db.exec('BEGIN')
    Definition.install(@manifest) { |sql| @db.exec(sql) }
    @db.exec('COMMIT')
  rescue StandardError
    @db.exec('ROLLBACK')
    raise
  end

  def markers
    ToybacoDurableStateProbe.new(@db, @manifest).read('b' * 32).fetch('markers')
  end

  def insert(table, id = 1, **values)
    columns = ['id'] + values.keys.map(&:to_s)
    parameters = [id] + values.values
    placeholders = parameters.each_index.map { |index| "$#{index + 1}" }
    @db.exec_params("INSERT INTO #{table} (#{columns.join(', ')}) VALUES (#{placeholders.join(', ')})", parameters)
  end

  def test_empty_and_ordinary_accounts_do_not_require_capabilities
    install
    insert('accounts', 4)
    @db.exec(%q(UPDATE accounts SET internal_attributes='{"display":"fixture"}' WHERE id=4))
    assert markers.values.none?
    assert_equal 0, @db.exec("SELECT * FROM #{Definition::TABLE}").ntuples
  end

  def test_every_declared_acceptance_survives_business_delete_and_truncate
    install
    Definition.bindings(Definition::SOURCES.keys).each_with_index do |(name, table, rule), index|
      values = case rule
               when 'account_keys' then { internal_attributes: JSON.generate(Definition::ACCOUNT_KEYS.first => nil) }
               when 'opening_checkout' then { action: 'opening_checkout' }
               when 'execution_v3' then { request: '{"version":3}' }
               else {}
               end
      insert(table, index + 1, **values)
      @db.exec("DELETE FROM #{table}")
      @db.exec("TRUNCATE #{table} CASCADE")
      assert markers.fetch(name), "lost #{name} from #{table}"
    end
    assert markers.values.all?
  end

  def test_account_cascade_cannot_erase_accepted_growth_state
    install
    insert('accounts', 4)
    insert('toybaco_growth_free_returns', 1, account_id: 4)
    @db.exec('DELETE FROM accounts WHERE id=4')
    assert_equal '0', @db.exec('SELECT count(*) FROM toybaco_growth_free_returns').first.values.first
    assert markers.fetch('growth-retention-v1')
    assert_equal [Definition::TABLE], @db.exec("SELECT table_name FROM information_schema.columns WHERE column_name='capability'").map(&:values).flatten
  end

  def test_seed_preserves_preexisting_evidence_without_changing_business_rows
    insert('accounts', 4, internal_attributes: '{"toybaco_growth_inbox_retention":null}')
    insert('toybaco_billing_events', 1, action: 'opening_checkout')
    before = @db.exec('SELECT row_to_json(accounts)::text FROM accounts').to_a
    install
    assert_equal before, @db.exec('SELECT row_to_json(accounts)::text FROM accounts').to_a
    assert markers.fetch('growth-retention-v1')
    assert markers.fetch('billing-ingress-v1')
    assert markers.fetch('opening-ingress-v1')
    refute markers.fetch('managed-auto-v1')
  end

  def test_whole_transaction_and_savepoint_rollback_do_not_mark_accepted
    install
    @db.exec('BEGIN')
    insert('toybaco_billing_events')
    @db.exec('ROLLBACK')
    refute markers.fetch('billing-ingress-v1')
    @db.exec('BEGIN; SAVEPOINT before_accept')
    insert('toybaco_growth_auto_requests')
    @db.exec('ROLLBACK TO SAVEPOINT before_accept; COMMIT')
    refute markers.fetch('managed-auto-v1')
  end

  def test_released_savepoint_and_deleted_receipt_still_mark_accepted
    install
    @db.exec('BEGIN; SAVEPOINT accept')
    insert('toybaco_growth_auto_requests')
    @db.exec('RELEASE SAVEPOINT accept; DELETE FROM toybaco_growth_auto_requests; COMMIT')
    assert markers.fetch('managed-auto-v1')
  end

  def test_concurrent_first_acceptances_commit_one_permanent_marker
    install
    @db.exec('BEGIN')
    insert('toybaco_billing_events', 1)
    ready = Queue.new
    worker = Thread.new do
      other = PG.connect(@url)
      ready << true
      other.exec("INSERT INTO toybaco_billing_events (id) VALUES (2)")
    ensure
      other&.close
    end
    Timeout.timeout(5) { ready.pop }
    @db.exec('COMMIT')
    assert worker.join(5)
    worker.value
    assert_equal '1', @db.exec("SELECT count(*) FROM #{Definition::TABLE} WHERE capability='billing-ingress-v1'").first.values.first
    assert_equal '2', @db.exec('SELECT count(*) FROM toybaco_billing_events').first.values.first
  ensure
    worker&.kill&.join if worker&.alive?
  end

  def test_opening_event_is_marked_before_request_and_other_billing_is_not_opening
    install
    insert('toybaco_billing_events', 1)
    refute markers.fetch('opening-ingress-v1')
    @db.exec("UPDATE toybaco_billing_events SET action='opening_checkout' WHERE id=1")
    @db.exec('DELETE FROM toybaco_billing_events')
    assert_equal '0', @db.exec('SELECT count(*) FROM toybaco_opening_requests').first.values.first
    assert markers.fetch('opening-ingress-v1')
  end

  def test_authority_v3_is_distinct_from_existing_v2_execution
    install
    insert('toybaco_growth_posting_executions', 1)
    assert markers.fetch('growth-retention-v1')
    refute markers.fetch('posting-authority-v1')
    @db.exec(%q(UPDATE toybaco_growth_posting_executions SET request='{"version":3}' WHERE id=1))
    @db.exec('DELETE FROM toybaco_growth_posting_executions')
    assert markers.fetch('posting-authority-v1')
  end

  def test_unknown_execution_version_is_not_hidden_by_permanent_history
    install
    insert('toybaco_growth_posting_executions', 1, request: '{"version":4}')
    assert_raises(ToybacoDurableStateProbe::Denied) { markers }
  end

  def test_permanent_marker_rejects_update_delete_and_truncate
    install
    insert('toybaco_billing_events')
    ["UPDATE #{Definition::TABLE} SET accepted_at=statement_timestamp()", "DELETE FROM #{Definition::TABLE}", "TRUNCATE #{Definition::TABLE}"].each do |sql|
      assert_raises(PG::CheckViolation) { @db.exec(sql) }
    end
    assert markers.fetch('billing-ingress-v1')
  end

  def test_invalid_name_or_time_is_rejected_or_probe_denied
    install
    assert_raises(PG::CheckViolation) { @db.exec("INSERT INTO #{Definition::TABLE} VALUES ('unknown', now())") }
    assert_raises(PG::CheckViolation) { @db.exec("INSERT INTO #{Definition::TABLE} VALUES ('billing-ingress-v1', 'infinity')") }
    @db.exec("INSERT INTO #{Definition::TABLE} VALUES ('billing-ingress-v1', now() + interval '1 day')")
    assert_raises(ToybacoDurableStateProbe::Denied) { markers }
  end

  def test_missing_marker_table_and_disabled_source_trigger_fail_closed
    install
    @db.exec('ALTER TABLE toybaco_billing_events DISABLE TRIGGER toybaco_accept_billing_ingress_v1')
    assert_raises(ToybacoDurableStateProbe::Denied) { markers }
    @db.exec('ALTER TABLE toybaco_billing_events ENABLE TRIGGER toybaco_accept_billing_ingress_v1')
    @db.exec("DROP TABLE #{Definition::TABLE} CASCADE")
    assert_raises(ToybacoDurableStateProbe::Denied) { markers }
  end

  def test_source_trigger_bypass_does_not_turn_existing_evidence_into_false
    install
    @db.exec('ALTER TABLE toybaco_billing_events DISABLE TRIGGER toybaco_accept_billing_ingress_v1')
    insert('toybaco_billing_events')
    @db.exec('ALTER TABLE toybaco_billing_events ENABLE TRIGGER toybaco_accept_billing_ingress_v1')
    assert_raises(ToybacoDurableStateProbe::Denied) { markers }
  end

  def test_function_body_and_extra_marker_trigger_drift_fail_closed
    install
    @db.exec("ALTER FUNCTION public.#{Definition::RECORDER}() SECURITY DEFINER")
    assert_raises(ToybacoDurableStateProbe::Denied) { markers }
    @db.exec("ALTER FUNCTION public.#{Definition::RECORDER}() SECURITY INVOKER")
    @db.exec('CREATE FUNCTION suppress_marker() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NULL; END $$')
    @db.exec("CREATE TRIGGER suppress BEFORE INSERT ON #{Definition::TABLE} FOR EACH ROW EXECUTE FUNCTION suppress_marker()")
    assert_raises(ToybacoDurableStateProbe::Denied) { markers }
  end

  def test_later_notice_extension_is_required_when_advertised
    install
    @manifest.fetch('capabilities').fetch('opening-ingress-v1').fetch('tables') << 'toybaco_opening_notices'
    @db.exec('CREATE TABLE toybaco_opening_notices (id bigint PRIMARY KEY)')
    assert_raises(ToybacoDurableStateProbe::Denied) { markers }
    @db.exec('BEGIN')
    Definition.extend_source('opening-ingress-v1', 'toybaco_opening_notices') { |sql| @db.exec(sql) }
    @db.exec('COMMIT')
    insert('toybaco_opening_notices')
    @db.exec('DELETE FROM toybaco_opening_notices')
    assert markers.fetch('opening-ingress-v1')
  end

  def test_actual_migrations_and_cascade_preserve_the_permanent_marker
    require 'active_record'
    ActiveRecord::Base.establish_connection(adapter: 'postgresql', host: @db.host, port: @db.port, database: @db.db,
                                          username: @db.user, password: @db.pass)
    connected = true
    ActiveRecord::Migration.verbose = false
    tables = Definition.bindings(Definition::SOURCES.keys).map { |_, table, _| table }.uniq - ['accounts']
    @db.exec("DROP TABLE #{tables.join(', ')} CASCADE")
    app = File.dirname(File.dirname(ENV.fetch('TOYBACO_DURABLE_PROBE_SOURCE', '/app/bin/toybaco-durable-state-probe.rb')))
    versions = %w[20260921000000 20260921010000 20260922010000 20260922020000 20260922030000 20260923000000
                  20260923010000 20260924000000 20260924020000 20260924030000 20260924040000 20260924050000 20260924060000 20260924070000 20260924080000 20260924090000 20260924100000 20260924110000 20260924120000 20260924130000 20260924140000
                  20260924150000]
    versions.each do |version|
      path = Dir.glob("#{app}/db/migrate/#{version}_*.rb").sole
      require path
      name = File.basename(path, '.rb').delete_prefix("#{version}_").camelize
      ActiveRecord::Base.transaction { Object.const_get(name).new.migrate(:up) }
    end
    @manifest.fetch('capabilities').fetch('opening-ingress-v1').fetch('tables') << 'toybaco_opening_notices'
    assert markers.values.none?
    insert('accounts', 4)
    @db.exec(%q(INSERT INTO toybaco_growth_free_returns (account_id,transition_id,receipt,created_at,updated_at)
      VALUES (4,'fixture','{}',now(),now())))
    @db.exec('DELETE FROM accounts WHERE id=4')
    assert_equal '0', @db.exec('SELECT count(*) FROM toybaco_growth_free_returns').first.values.first
    assert markers.fetch('growth-retention-v1')
    @db.exec(%q(INSERT INTO toybaco_billing_events
      (event_id,mode,action,reference_id,payload_digest,deadline_at,next_attempt_at,created_at,updated_at)
      VALUES ('evt_fixture','test','opening_checkout','cs_fixture','fixture',now()+interval '1 day',now(),now(),now())))
    @db.exec('DELETE FROM toybaco_billing_events')
    assert markers.fetch('billing-ingress-v1')
    assert markers.fetch('opening-ingress-v1')
    assert_equal '0', @db.exec('SELECT count(*) FROM toybaco_opening_requests').first.values.first
  ensure
    ActiveRecord::Base.connection_pool.disconnect! if connected
  end

  def without_capabilities(*names)
    names.each do |name|
      @manifest.fetch('capabilities').delete(name)
      Definition::SOURCES.fetch(name).each_key { |table| @db.exec("DROP TABLE #{table}") }
    end
  end

  def without_renewal_dispatch
    without_capabilities('renewal-dispatch-v1')
  end

  def without_scheduled_grant_upgrade
    without_renewal_dispatch
    without_capabilities('scheduled-grant-upgrade-v1')
  end

  def without_provider_settlement
    without_scheduled_grant_upgrade
    without_capabilities('renewal-provider-settlement-v1')
  end

  def without_scheduled_downgrade
    without_provider_settlement
    without_capabilities('scheduled-downgrade-grace-v1')
  end

  def without_coordinator
    without_scheduled_downgrade
    without_capabilities('renewal-settlement-v1')
  end

  def without_after_posting_renewal
    without_scheduled_downgrade
    without_capabilities('posting-paid-upgrade-v1', 'renewal-settlement-v1')
  end

  def base_without_future
    without_after_posting_renewal
    @manifest.fetch('capabilities').delete('posting-renewal-v1')
    Definition::SOURCES.fetch('posting-renewal-v1').each_key { |table| @db.exec("DROP TABLE #{table}") }
    future = @manifest.fetch('capabilities').delete('renewal-ingress-v1')
    Definition::SOURCES.fetch('renewal-ingress-v1').each_key { |table| @db.exec("DROP TABLE #{table}") }
    install
    assert markers.values.none?
    future
  end

  def future_tables
    Definition::SOURCES.fetch('renewal-ingress-v1').each_key do |table|
      @db.exec("CREATE TABLE #{table} (id bigint PRIMARY KEY)")
    end
  end

  def test_later_capability_after_base_and_notice_migrations_keeps_minimal_permanent_evidence
    future = base_without_future
    @db.exec('CREATE TABLE toybaco_opening_notices (id bigint PRIMARY KEY)')
    @manifest.fetch('capabilities').fetch('opening-ingress-v1').fetch('tables') << 'toybaco_opening_notices'
    @db.exec('BEGIN')
    Definition.extend_source('opening-ingress-v1', 'toybaco_opening_notices') { |sql| @db.exec(sql) }
    @db.exec('COMMIT')
    assert markers.values.none?
    @db.exec('BEGIN')
    future_tables
    Definition.add_capability('renewal-ingress-v1') { |sql| @db.exec(sql) }
    @db.exec('COMMIT')
    assert_raises(ToybacoDurableStateProbe::Denied) { markers }
    @manifest.fetch('capabilities')['renewal-ingress-v1'] = future
    refute markers.fetch('renewal-ingress-v1')
    @db.exec('BEGIN')
    insert('toybaco_renewal_operations')
    @db.exec('ROLLBACK')
    refute markers.fetch('renewal-ingress-v1')
    insert('toybaco_renewal_invoice_facts')
    @db.exec('DELETE FROM toybaco_renewal_invoice_facts')
    assert markers.fetch('renewal-ingress-v1')
    @manifest.fetch('capabilities').delete('renewal-ingress-v1')
    @db.exec('DROP TABLE toybaco_renewal_invoice_facts, toybaco_renewal_operations')
    assert_raises(ToybacoDurableStateProbe::Denied) { markers }
  end

  def test_later_capability_failure_rolls_back_new_tables_and_old_catalog_change
    base_without_future
    require 'active_record'
    ActiveRecord::Base.establish_connection(adapter: 'postgresql', host: @db.host, port: @db.port, database: @db.db,
                                          username: @db.user, password: @db.pass)
    connected = true
    ActiveRecord::Migration.verbose = false
    app = File.dirname(File.dirname(ENV.fetch('TOYBACO_DURABLE_PROBE_SOURCE', '/app/bin/toybaco-durable-state-probe.rb')))
    require "#{app}/db/migrate/20260924080000_create_toybaco_renewal_ingress"
    migration = CreateToybacoRenewalIngress.new
    migration.define_singleton_method(:execute) do |sql, **options|
      super(sql, **options)
      connection.execute('SELECT missing_renewal_fixture_function()') if sql.include?('EXISTS') && sql.include?('toybaco_renewal_operations')
    end
    assert_raises(ActiveRecord::StatementInvalid) { ActiveRecord::Base.transaction { migration.migrate(:up) } }
    assert_nil @db.exec("SELECT to_regclass('toybaco_renewal_invoice_facts')").first.values.first
    assert_nil @db.exec("SELECT to_regclass('toybaco_renewal_operations')").first.values.first
    assert markers.values.none?
    assert_raises(PG::CheckViolation) { @db.exec("INSERT INTO #{Definition::TABLE} VALUES ('renewal-ingress-v1', now())") }
  ensure
    ActiveRecord::Base.connection_pool.disconnect! if connected
  end

  def test_posting_renewal_expansion_keeps_prior_capabilities_and_permanent_evidence
    without_after_posting_renewal
    future = @manifest.fetch('capabilities').delete('posting-renewal-v1')
    @db.exec('DROP TABLE toybaco_growth_posting_renewals')
    install
    insert('toybaco_renewal_operations')
    @db.exec('BEGIN')
    @db.exec('CREATE TABLE toybaco_growth_posting_renewals (id bigint PRIMARY KEY)')
    Definition.add_capability('posting-renewal-v1') { |sql| @db.exec(sql) }
    @db.exec('COMMIT')
    assert_raises(ToybacoDurableStateProbe::Denied) { markers }
    @manifest.fetch('capabilities')['posting-renewal-v1'] = future
    assert markers.fetch('renewal-ingress-v1')
    refute markers.fetch('posting-renewal-v1')
    @db.exec('BEGIN')
    @db.exec('SAVEPOINT before_receipt')
    insert('toybaco_growth_posting_renewals')
    @db.exec('ROLLBACK TO before_receipt')
    @db.exec('COMMIT')
    refute markers.fetch('posting-renewal-v1')
    insert('toybaco_growth_posting_renewals')
    @db.exec('TRUNCATE toybaco_growth_posting_renewals')
    assert markers.fetch('posting-renewal-v1')
    @manifest.fetch('capabilities').delete('posting-renewal-v1')
    @db.exec('DROP TABLE toybaco_growth_posting_renewals')
    assert_raises(ToybacoDurableStateProbe::Denied) { markers }
  end

  def test_posting_renewal_migration_failure_rolls_back_table_and_capability_expansion
    without_after_posting_renewal
    @manifest.fetch('capabilities').delete('posting-renewal-v1')
    @db.exec('DROP TABLE toybaco_growth_posting_renewals')
    install
    require 'active_record'
    ActiveRecord::Base.establish_connection(adapter: 'postgresql', host: @db.host, port: @db.port, database: @db.db,
                                          username: @db.user, password: @db.pass)
    connected = true
    ActiveRecord::Migration.verbose = false
    app = File.dirname(File.dirname(ENV.fetch('TOYBACO_DURABLE_PROBE_SOURCE', '/app/bin/toybaco-durable-state-probe.rb')))
    require "#{app}/db/migrate/20260924090000_create_toybaco_growth_posting_renewals"
    migration = CreateToybacoGrowthPostingRenewals.new
    migration.define_singleton_method(:execute) do |sql, **options|
      super(sql, **options)
      connection.execute('SELECT missing_renewal_fixture_function()') if sql.include?('EXISTS') && sql.include?('toybaco_growth_posting_renewals')
    end
    assert_raises(ActiveRecord::StatementInvalid) { ActiveRecord::Base.transaction { migration.migrate(:up) } }
    assert_nil @db.exec("SELECT to_regclass('toybaco_growth_posting_renewals')").first.values.first
    assert markers.values.none?
    assert_raises(PG::CheckViolation) { @db.exec("INSERT INTO #{Definition::TABLE} VALUES ('posting-renewal-v1', now())") }
  ensure
    ActiveRecord::Base.connection_pool.disconnect! if connected
  end

  def test_renewal_coordinator_expansion_rollback_delete_and_old_manifest_are_fail_closed
    future = @manifest.fetch('capabilities').fetch('renewal-settlement-v1')
    without_coordinator
    install
    insert('toybaco_renewal_operations')
    @db.exec('BEGIN')
    @db.exec('CREATE TABLE toybaco_growth_renewal_coordinators (id bigint PRIMARY KEY)')
    Definition.add_capability('renewal-settlement-v1') { |sql| @db.exec(sql) }
    @db.exec('ROLLBACK')
    assert_nil @db.exec("SELECT to_regclass('toybaco_growth_renewal_coordinators')").first.values.first
    assert markers.fetch('renewal-ingress-v1')
    @db.exec('BEGIN')
    @db.exec('CREATE TABLE toybaco_growth_renewal_coordinators (id bigint PRIMARY KEY)')
    Definition.add_capability('renewal-settlement-v1') { |sql| @db.exec(sql) }
    @db.exec('COMMIT')
    assert_raises(ToybacoDurableStateProbe::Denied) { markers }
    @manifest.fetch('capabilities')['renewal-settlement-v1'] = future
    refute markers.fetch('renewal-settlement-v1')
    @db.exec('BEGIN')
    insert('toybaco_growth_renewal_coordinators')
    @db.exec('ROLLBACK')
    refute markers.fetch('renewal-settlement-v1')
    insert('toybaco_growth_renewal_coordinators')
    @db.exec('DELETE FROM toybaco_growth_renewal_coordinators')
    assert markers.fetch('renewal-settlement-v1')
    @manifest.fetch('capabilities').delete('renewal-settlement-v1')
    @db.exec('DROP TABLE toybaco_growth_renewal_coordinators')
    assert_raises(ToybacoDurableStateProbe::Denied) { markers }
  end

  def test_coordinator_migration_fault_rolls_back_table_constraint_and_trigger
    without_coordinator
    install
    require 'active_record'
    ActiveRecord::Base.establish_connection(adapter: 'postgresql', host: @db.host, port: @db.port, database: @db.db,
                                          username: @db.user, password: @db.pass)
    connected = true
    ActiveRecord::Migration.verbose = false
    app = File.dirname(File.dirname(ENV.fetch('TOYBACO_DURABLE_PROBE_SOURCE', '/app/bin/toybaco-durable-state-probe.rb')))
    require "#{app}/db/migrate/20260924110000_create_toybaco_growth_renewal_coordinators"
    migration = CreateToybacoGrowthRenewalCoordinators.new
    migration.define_singleton_method(:execute) do |sql, **options|
      super(sql, **options)
      connection.execute('SELECT missing_coordinator_fixture_function()') if sql.include?('EXISTS') && sql.include?('toybaco_growth_renewal_coordinators')
    end
    assert_raises(ActiveRecord::StatementInvalid) { ActiveRecord::Base.transaction { migration.migrate(:up) } }
    assert_nil @db.exec("SELECT to_regclass('toybaco_growth_renewal_coordinators')").first.values.first
    assert markers.values.none?
    assert_raises(PG::CheckViolation) { @db.exec("INSERT INTO #{Definition::TABLE} VALUES ('renewal-settlement-v1', now())") }
  ensure
    ActiveRecord::Base.connection_pool.disconnect! if connected
  end

  def test_scheduled_downgrade_expansion_retains_earlier_markers_and_denies_old_manifest
    future = @manifest.fetch('capabilities').fetch('scheduled-downgrade-grace-v1')
    without_scheduled_downgrade
    install
    insert('toybaco_growth_posting_paid_upgrades')
    insert('toybaco_growth_renewal_coordinators')
    @db.exec('BEGIN')
    @db.exec('CREATE TABLE toybaco_growth_scheduled_downgrades (id bigint PRIMARY KEY)')
    Definition.add_capability('scheduled-downgrade-grace-v1') { |sql| @db.exec(sql) }
    @db.exec('COMMIT')
    assert_raises(ToybacoDurableStateProbe::Denied) { markers }
    @manifest.fetch('capabilities')['scheduled-downgrade-grace-v1'] = future
    assert markers.fetch('posting-paid-upgrade-v1')
    assert markers.fetch('renewal-settlement-v1')
    refute markers.fetch('scheduled-downgrade-grace-v1')
    @db.exec('BEGIN')
    insert('toybaco_growth_scheduled_downgrades')
    @db.exec('ROLLBACK')
    refute markers.fetch('scheduled-downgrade-grace-v1')
    insert('toybaco_growth_scheduled_downgrades')
    @db.exec('DELETE FROM toybaco_growth_scheduled_downgrades')
    @db.exec('TRUNCATE toybaco_growth_scheduled_downgrades')
    assert markers.fetch('scheduled-downgrade-grace-v1')
    @manifest.fetch('capabilities').delete('scheduled-downgrade-grace-v1')
    @db.exec('DROP TABLE toybaco_growth_scheduled_downgrades')
    assert_raises(ToybacoDurableStateProbe::Denied) { markers }
  end

  def test_scheduled_downgrade_migration_fault_rolls_back_table_constraint_and_trigger
    without_scheduled_downgrade
    install
    require 'active_record'
    ActiveRecord::Base.establish_connection(adapter: 'postgresql', host: @db.host, port: @db.port, database: @db.db,
                                          username: @db.user, password: @db.pass)
    connected = true
    ActiveRecord::Migration.verbose = false
    app = File.dirname(File.dirname(ENV.fetch('TOYBACO_DURABLE_PROBE_SOURCE', '/app/bin/toybaco-durable-state-probe.rb')))
    require "#{app}/db/migrate/20260924120000_create_toybaco_growth_scheduled_downgrades"
    migration = CreateToybacoGrowthScheduledDowngrades.new
    migration.define_singleton_method(:execute) do |sql, **options|
      super(sql, **options)
      connection.execute('SELECT missing_scheduled_fixture_function()') if sql.include?('EXISTS') && sql.include?('toybaco_growth_scheduled_downgrades')
    end
    assert_raises(ActiveRecord::StatementInvalid) { ActiveRecord::Base.transaction { migration.migrate(:up) } }
    assert_nil @db.exec("SELECT to_regclass('toybaco_growth_scheduled_downgrades')").first.values.first
    assert markers.values.none?
    assert_raises(PG::CheckViolation) { @db.exec("INSERT INTO #{Definition::TABLE} VALUES ('scheduled-downgrade-grace-v1', now())") }
  ensure
    ActiveRecord::Base.connection_pool.disconnect! if connected
  end

  def test_provider_settlement_expansion_keeps_prior_markers_and_minimal_history
    future = @manifest.fetch('capabilities').fetch('renewal-provider-settlement-v1')
    without_provider_settlement
    install
    insert('toybaco_growth_scheduled_downgrades')
    @db.exec('BEGIN')
    @db.exec('CREATE TABLE toybaco_growth_renewal_settlements (id bigint PRIMARY KEY)')
    Definition.add_capability('renewal-provider-settlement-v1') { |sql| @db.exec(sql) }
    @db.exec('COMMIT')
    assert_raises(ToybacoDurableStateProbe::Denied) { markers }
    @manifest.fetch('capabilities')['renewal-provider-settlement-v1'] = future
    assert markers.fetch('scheduled-downgrade-grace-v1')
    refute markers.fetch('renewal-provider-settlement-v1')
    @db.exec('BEGIN')
    insert('toybaco_growth_renewal_settlements')
    @db.exec('ROLLBACK')
    refute markers.fetch('renewal-provider-settlement-v1')
    insert('toybaco_growth_renewal_settlements')
    @db.exec('DELETE FROM toybaco_growth_renewal_settlements')
    @db.exec('TRUNCATE toybaco_growth_renewal_settlements')
    assert markers.fetch('renewal-provider-settlement-v1')
    @manifest.fetch('capabilities').delete('renewal-provider-settlement-v1')
    @db.exec('DROP TABLE toybaco_growth_renewal_settlements')
    assert_raises(ToybacoDurableStateProbe::Denied) { markers }
  end

  def test_scheduled_grant_upgrade_expansion_keeps_prior_markers_and_minimal_history
    future = @manifest.fetch('capabilities').fetch('scheduled-grant-upgrade-v1')
    without_scheduled_grant_upgrade
    install
    insert('toybaco_growth_renewal_settlements')
    @db.exec('BEGIN')
    @db.exec('CREATE TABLE toybaco_growth_scheduled_grant_upgrades (id bigint PRIMARY KEY)')
    Definition.add_capability('scheduled-grant-upgrade-v1') { |sql| @db.exec(sql) }
    @db.exec('COMMIT')
    assert_raises(ToybacoDurableStateProbe::Denied) { markers }
    @manifest.fetch('capabilities')['scheduled-grant-upgrade-v1'] = future
    assert markers.fetch('renewal-provider-settlement-v1')
    refute markers.fetch('scheduled-grant-upgrade-v1')
    @db.exec('BEGIN')
    insert('toybaco_growth_scheduled_grant_upgrades')
    @db.exec('ROLLBACK')
    refute markers.fetch('scheduled-grant-upgrade-v1')
    insert('toybaco_growth_scheduled_grant_upgrades')
    @db.exec('DELETE FROM toybaco_growth_scheduled_grant_upgrades')
    @db.exec('TRUNCATE toybaco_growth_scheduled_grant_upgrades')
    assert markers.fetch('scheduled-grant-upgrade-v1')
    @manifest.fetch('capabilities').delete('scheduled-grant-upgrade-v1')
    @db.exec('DROP TABLE toybaco_growth_scheduled_grant_upgrades')
    assert_raises(ToybacoDurableStateProbe::Denied) { markers }
  end

  def test_renewal_dispatch_expansion_keeps_prior_markers_and_minimal_history
    future = @manifest.fetch('capabilities').fetch('renewal-dispatch-v1')
    without_renewal_dispatch
    install
    insert('toybaco_growth_scheduled_grant_upgrades')
    @db.exec('BEGIN')
    @db.exec('CREATE TABLE toybaco_growth_renewal_dispatches (id bigint PRIMARY KEY)')
    Definition.add_capability('renewal-dispatch-v1') { |sql| @db.exec(sql) }
    @db.exec('COMMIT')
    assert_raises(ToybacoDurableStateProbe::Denied) { markers }
    @manifest.fetch('capabilities')['renewal-dispatch-v1'] = future
    assert markers.fetch('scheduled-grant-upgrade-v1')
    refute markers.fetch('renewal-dispatch-v1')
    @db.exec('BEGIN')
    insert('toybaco_growth_renewal_dispatches')
    @db.exec('ROLLBACK')
    refute markers.fetch('renewal-dispatch-v1')
    insert('toybaco_growth_renewal_dispatches')
    @db.exec('DELETE FROM toybaco_growth_renewal_dispatches')
    @db.exec('TRUNCATE toybaco_growth_renewal_dispatches')
    assert markers.fetch('renewal-dispatch-v1')
    @manifest.fetch('capabilities').delete('renewal-dispatch-v1')
    @db.exec('DROP TABLE toybaco_growth_renewal_dispatches')
    assert_raises(ToybacoDurableStateProbe::Denied) { markers }
  end

  def test_install_failure_rolls_back_functions_table_and_triggers
    count = 0
    @db.exec('BEGIN')
    assert_raises(PG::UndefinedFunction) do
      Definition.install(@manifest) do |sql|
        @db.exec(sql)
        count += 1
        @db.exec('SELECT missing_fixture_function()') if count == 15
      end
    end
    @db.exec('ROLLBACK')
    assert_nil @db.exec("SELECT to_regclass('#{Definition::TABLE}')::text").first.values.first
    assert_equal '0', @db.exec("SELECT count(*) FROM pg_trigger WHERE tgname LIKE 'toybaco_accept_%'").first.values.first
  end
end
