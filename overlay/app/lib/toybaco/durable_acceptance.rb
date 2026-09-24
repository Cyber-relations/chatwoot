# frozen_string_literal: true

require 'json'
require_relative 'durable_acceptance_definition'

# No tenant identifiers or payloads: this is a permanent rollback boundary.
module Toybaco::DurableAcceptance
  class Invalid < StandardError; end

  include Toybaco::DurableAcceptanceDefinition

  module_function

  def capabilities!(manifest)
    capabilities = manifest.fetch('capabilities')
    raise Invalid unless capabilities.is_a?(Hash) && capabilities.any? && (capabilities.keys - SOURCES.keys).empty?

    capabilities.each { |name, value| validate_capability!(name, value) }
    capabilities.keys.sort
  rescue KeyError, NoMethodError, TypeError
    raise Invalid
  end

  def validate_capability!(name, value)
    expected = SOURCES.fetch(name).reject { |table, rule| table == 'accounts' || rule == 'execution_v3' }.keys
    expected = (expected + [TABLE] + (value.fetch('tables') & EXTENSIONS.fetch(name, {}).keys)).sort
    keys = name == 'growth-retention-v1' ? ACCOUNT_KEYS : []
    raise Invalid unless value.fetch('tables').sort == expected && value.fetch('account_keys', []).sort == keys.sort
  end

  def bindings(names, extensions: [])
    names.flat_map { |name| SOURCES.fetch(name).map { |table, rule| [name, table, rule] } } + extensions
  end

  def extensions(manifest)
    manifest.fetch('capabilities').flat_map do |name, value|
      EXTENSIONS.fetch(name, {}).filter_map { |table, rule| [name, table, rule] if value.fetch('tables').include?(table) }
    end
  end

  # A later migration calls this only after creating its source table. The
  # base migration never requires a table owned by a later migration.
  def extend_source(name, table)
    rule = EXTENSIONS.fetch(name).fetch(table)
    yield "LOCK TABLE public.#{table} IN SHARE ROW EXCLUSIVE MODE"
    yield trigger_sql(source_trigger(name, table, rule))
    yield seed_sql(name, table, rule)
  end

  def seed_sql(name, table, rule)
    "INSERT INTO public.#{TABLE} (capability) SELECT '#{name}' WHERE EXISTS (#{evidence_sql(table, rule)}) " \
      'ON CONFLICT (capability) DO NOTHING'
  end

  def trigger_name(name)
    "toybaco_accept_#{name.tr('-', '_')}"
  end

  def function_sql(name, body)
    "CREATE FUNCTION public.#{name}() RETURNS trigger LANGUAGE plpgsql VOLATILE SECURITY INVOKER " \
      "SET search_path = pg_catalog, public AS $function$\n#{body}$function$"
  end

  def acceptance_check(names)
    "capability = ANY (ARRAY[#{names.map { |name| "'#{name}'::text" }.join(', ')}])"
  end

  def table_sql(names)
    <<~SQL.squish
      CREATE TABLE public.#{TABLE} (
        capability text NOT NULL,
        accepted_at timestamp with time zone NOT NULL DEFAULT transaction_timestamp(),
        CONSTRAINT toybaco_durable_acceptance_pk PRIMARY KEY (capability),
        CONSTRAINT toybaco_durable_acceptance_name CHECK (#{acceptance_check(names)}),
        CONSTRAINT toybaco_durable_acceptance_time CHECK (isfinite(accepted_at))
      )
    SQL
  end

  def source_trigger(name, table, rule)
    { name: trigger_name(name), table: table, function: RECORDER, type: 21, args: [name, rule],
      event: 'AFTER INSERT OR UPDATE FOR EACH ROW' }
  end

  def triggers(names, extensions: [])
    rows = bindings(names, extensions: extensions).map { |name, table, rule| source_trigger(name, table, rule) }
    rows + [
      { name: 'toybaco_durable_acceptance_immutable_row', table: TABLE, function: IMMUTABLE, type: 27, args: [],
        event: 'BEFORE UPDATE OR DELETE FOR EACH ROW' },
      { name: 'toybaco_durable_acceptance_immutable_truncate', table: TABLE, function: IMMUTABLE, type: 34, args: [],
        event: 'BEFORE TRUNCATE FOR EACH STATEMENT' }
    ]
  end

  def trigger_sql(row)
    timing, granularity = row.fetch(:event).split(' FOR EACH ')
    arguments = row.fetch(:args).map { |value| "'#{value}'" }.join(', ')
    "CREATE TRIGGER #{row.fetch(:name)} #{timing} ON public.#{row.fetch(:table)} FOR EACH #{granularity} " \
      "EXECUTE FUNCTION public.#{row.fetch(:function)}(#{arguments})"
  end

  def evidence_sql(table, rule)
    predicate = case rule
                when 'always' then 'true'
                when 'account_keys' then "internal_attributes::jsonb ?| ARRAY[#{ACCOUNT_KEYS.map { |key| "'#{key}'" }.join(', ')}]::text[]"
                when 'opening_checkout' then "action = 'opening_checkout'"
                when 'execution_v3' then "request->>'version' = '3'"
                else raise Invalid
                end
    "SELECT 1 FROM public.#{table} WHERE #{predicate}"
  end

  def install(manifest)
    names = capabilities!(manifest)
    tables = bindings(names).map { |_, table, _| table }.uniq.sort
    yield "LOCK TABLE #{tables.map { |table| "public.#{table}" }.join(', ')} IN SHARE ROW EXCLUSIVE MODE"
    yield table_sql(names)
    yield function_sql(RECORDER, RECORDER_BODY)
    yield function_sql(IMMUTABLE, IMMUTABLE_BODY)
    triggers(names).each { |row| yield trigger_sql(row) }
    bindings(names).each { |name, table, rule| yield seed_sql(name, table, rule) }
  end
end

require_relative 'durable_acceptance_expansion'
Toybaco::DurableAcceptance.extend(Toybaco::DurableAcceptanceExpansion)
