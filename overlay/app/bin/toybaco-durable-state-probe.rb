# frozen_string_literal: true

require 'digest'
require 'json'
require 'pg'
require_relative '../lib/toybaco/durable_acceptance_catalog'

# DB-only managed-deploy probe: no Rails boot, callbacks, queue or provider client.
class ToybacoDurableStateProbe
  class Denied < StandardError; end

  FUTURE_TABLES = %w[
    toybaco_growth_auto_installations toybaco_growth_auto_commands toybaco_growth_auto_requests
    toybaco_growth_posting_authorities toybaco_growth_posting_authority_currents
    toybaco_opening_requests toybaco_opening_notices toybaco_durable_capability_acceptances
    toybaco_renewal_invoice_facts toybaco_renewal_operations toybaco_growth_renewal_coordinators toybaco_growth_posting_renewals
    toybaco_growth_posting_paid_upgrades
    toybaco_growth_scheduled_downgrades toybaco_growth_renewal_settlements toybaco_growth_scheduled_grant_upgrades
    toybaco_growth_renewal_dispatches
  ].freeze

  def initialize(connection, manifest)
    @connection = connection
    @manifest = manifest
  end

  def read(nonce)
    validate!(nonce)
    readonly { snapshot(nonce) }
  end

  private

  def readonly
    started = false
    raise Denied unless @connection.transaction_status == PG::PQTRANS_IDLE

    @connection.exec('BEGIN ISOLATION LEVEL READ COMMITTED READ ONLY')
    started = true
    @connection.exec("SET LOCAL statement_timeout = '5s'")
    raise Denied unless @connection.exec('SHOW transaction_read_only').first.values == ['on']

    value = yield
    @connection.exec('COMMIT')
    value
  rescue StandardError
    @connection.exec('ROLLBACK') if started && @connection.transaction_status != PG::PQTRANS_IDLE
    raise
  end

  def snapshot(nonce)
    schema = schema_hash
    capabilities = @manifest.fetch('capabilities')
    declared = capabilities.values.flat_map { |value| value.fetch('tables') }
    undeclared!(capabilities, declared)

    markers = accepted_markers(capabilities, declared)
    { 'version' => 1, 'application' => 'chatwoot', 'schema_sha256' => schema, 'nonce' => nonce, 'markers' => markers }
  end

  def undeclared!(capabilities, declared)
    (FUTURE_TABLES - declared).each { |table| raise Denied if relation?(table) }
    raise Denied if !capabilities.key?('posting-authority-v1') && v3_execution_marker?
    raise Denied if !capabilities.key?('opening-ingress-v1') && opening_marker?
  end

  def accepted_markers(capabilities, declared)
    return capabilities.to_h { |name, value| [name, marker?(name, value)] } unless declared.include?(Toybaco::DurableAcceptance::TABLE)

    permanent = Toybaco::DurableAcceptanceCatalog.new(@connection, @manifest).read
    capabilities.to_h do |name, _|
      current = current_acceptance?(name)
      raise Denied if current && !permanent.fetch(name)

      [name, permanent.fetch(name)]
    end
  rescue Toybaco::DurableAcceptance::Invalid
    raise Denied
  end

  def current_acceptance?(name)
    v3_execution_marker? if name == 'posting-authority-v1'
    definition = Toybaco::DurableAcceptance
    extension = definition.extensions(@manifest).select { |row| row.first == name }
    definition.bindings([name], extensions: extension).map do |_, table, rule|
      table_marker?(table)
      @connection.exec("SELECT EXISTS (#{definition.evidence_sql(table, rule)}) AS present").first.fetch('present') == 't'
    end.any?
  end

  def opening_marker?
    return false unless relation?('toybaco_billing_events')

    query = "SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='toybaco_billing_events'"
    columns = @connection.exec(query)
    return false unless columns.any? { |row| row.fetch('column_name') == 'action' }

    table_marker?('toybaco_billing_events')
    query = "SELECT EXISTS (SELECT 1 FROM public.toybaco_billing_events WHERE action='opening_checkout') AS present"
    @connection.exec(query).first.fetch('present') == 't'
  end

  def schema_hash
    versions = @connection.exec('SELECT version FROM public.schema_migrations ORDER BY version COLLATE "C"').map { |row| row.fetch('version') }
    raise Denied unless versions.uniq == versions && versions.all? { |version| version.match?(/\A\d{14}\z/) }

    schema = Digest::SHA256.hexdigest("#{versions.join("\n")}\n")
    raise Denied unless @manifest.fetch('capabilities').values.all? { |value| value.fetch('schema_sha256') == schema }

    schema
  end

  def validate_header!(nonce)
    raise Denied unless nonce.is_a?(String) && nonce.match?(/\A[0-9a-f]{32}\z/)
    raise Denied unless @manifest['version'] == 1 && @manifest['application'] == 'chatwoot'
  end

  def validate!(nonce)
    validate_header!(nonce)
    capabilities = @manifest.fetch('capabilities')
    raise Denied unless capabilities.is_a?(Hash) && capabilities.any? && capabilities.size <= 14

    capabilities.each_value { |value| validate_capability!(value) }
  end

  def validate_capability!(value)
    raise Denied unless value.fetch('schema_sha256').match?(/\A[0-9a-f]{64}\z/)
    raise Denied unless value.fetch('tables').any?

    identifiers!(value['tables'], /\Atoybaco_[a-z_]+\z/)
    identifiers!(value.fetch('account_keys', []), /\Atoybaco_growth_[a-z_]+\z/)
  end

  def identifiers!(values, pattern)
    raise Denied unless values.is_a?(Array) && values.uniq == values && values.all? { |value| value.is_a?(String) && value.match?(pattern) }
  end

  def relation?(name)
    @connection.exec_params('SELECT to_regclass($1)::text AS name', ["public.#{name}"]).first.fetch('name')
  end

  def table_marker?(table)
    query = ['SELECT c.relkind, c.relpersistence, c.relrowsecurity, c.relforcerowsecurity, c.relhasrules,',
             'pg_get_userbyid(c.relowner) = current_user AS owned',
             'FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace',
             "WHERE n.nspname = 'public' AND c.relname = $1"].join(' ')
    catalog = @connection.exec_params(query, [table]).first
    raise Denied unless catalog == { 'relkind' => 'r', 'relpersistence' => 'p', 'relrowsecurity' => 'f',
                                     'relforcerowsecurity' => 'f', 'relhasrules' => 'f', 'owned' => 't' }

    @connection.exec("SELECT EXISTS (SELECT 1 FROM public.#{PG::Connection.quote_ident(table)}) AS present").first.fetch('present') == 't'
  end

  def v3_execution_marker?
    return false unless relation?('toybaco_growth_posting_executions')

    table_marker?('toybaco_growth_posting_executions')
    invalid = ['SELECT EXISTS (SELECT 1 FROM public.toybaco_growth_posting_executions',
               "WHERE request->>'version' IS NULL OR request->>'version' NOT IN ('2', '3')) AS present"].join(' ')
    raise Denied if @connection.exec(invalid).first.fetch('present') == 't'

    query = "SELECT EXISTS (SELECT 1 FROM public.toybaco_growth_posting_executions WHERE request->>'version' = '3') AS present"
    @connection.exec(query).first.fetch('present') == 't'
  end

  def marker?(name, value)
    # Do not short circuit: every declared table must exist and pass catalog checks.
    found = value.fetch('tables').map { |table| table_marker?(table) }.any?
    found = v3_execution_marker? || found if name == 'posting-authority-v1'
    keys = value.fetch('account_keys', [])
    return found if keys.empty?

    table_marker?('accounts')
    query = 'SELECT EXISTS (SELECT 1 FROM public.accounts WHERE internal_attributes::jsonb ?| $1::text[]) AS present'
    attributes = @connection.exec_params(query, [PG::TextEncoder::Array.new.encode(keys)]).first.fetch('present')
    found || attributes == 't'
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    manifest = JSON.parse(File.read('/app/config/toybaco-durable-capabilities.json'))
    connection = PG.connect(dbname: ENV.fetch('PGDATABASE'), user: ENV.fetch('PGUSER'), password: ENV.fetch('PGPASSWORD'),
                            host: ENV.fetch('PGHOST'), port: ENV.fetch('PGPORT', '5432'), sslmode: ENV.fetch('PGSSLMODE', 'require'),
                            options: '-c default_transaction_read_only=on', connect_timeout: 15)
    receipt = ToybacoDurableStateProbe.new(connection, manifest).read(ENV.fetch('TOYBACO_DURABLE_PROBE_NONCE'))
    puts "TOYBACO_DURABLE_PROBE=#{JSON.generate(receipt)}"
  rescue StandardError
    warn 'TOYBACO_DURABLE_PROBE=DENY'
    exit 78
  ensure
    connection&.close
  end
end
