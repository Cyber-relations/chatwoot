# frozen_string_literal: true

require_relative 'durable_acceptance'

# Verify the exact immutable history and trigger contract without Rails boot.
class Toybaco::DurableAcceptanceCatalog
  Definition = Toybaco::DurableAcceptance
  Invalid = Definition::Invalid

  def initialize(connection, manifest)
    @connection = connection
    @names = Definition.capabilities!(manifest)
    @extensions = Definition.extensions(manifest)
  end

  def read
    verify_table!
    verify_columns!
    verify_constraints!
    verify_functions!
    verify_triggers!
    rows = @connection.exec("SELECT capability FROM public.#{Definition::TABLE} ORDER BY capability COLLATE \"C\"").map(&:values).flatten
    raise Invalid unless rows.uniq == rows && (rows - @names).empty?

    raise Invalid unless @connection.exec("SELECT count(*) FROM public.#{Definition::TABLE} " \
                                          "WHERE accepted_at < TIMESTAMPTZ '1970-01-01 00:00:00+00' " \
                                          'OR accepted_at > statement_timestamp()').first.values == ['0']

    @names.zip(@names.map { |name| rows.include?(name) }).to_h
  end

  private

  def verify_table!
    row = @connection.exec_params(<<~SQL.squish, [Definition::TABLE]).first
      SELECT c.relkind, c.relpersistence, c.relrowsecurity, c.relforcerowsecurity, c.relhasrules,
        pg_get_userbyid(c.relowner) = current_user AS owned,
        NOT EXISTS (SELECT 1 FROM aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) a
          WHERE a.grantee <> c.relowner) AS private
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relname = $1
    SQL
    raise Invalid unless row == { 'relkind' => 'r', 'relpersistence' => 'p', 'relrowsecurity' => 'f',
                                  'relforcerowsecurity' => 'f', 'relhasrules' => 'f', 'owned' => 't', 'private' => 't' }
  end

  def verify_columns!
    rows = @connection.exec_params(<<~SQL.squish, [Definition::TABLE]).to_a
      SELECT a.attname, format_type(a.atttypid,a.atttypmod) AS type, a.attnotnull::text AS required,
        pg_get_expr(d.adbin,d.adrelid) AS default_value, a.attidentity, a.attgenerated
      FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace
      LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
      WHERE n.nspname='public' AND c.relname=$1 AND a.attnum>0 AND NOT a.attisdropped ORDER BY a.attnum
    SQL
    expected = [['capability', 'text', nil], ['accepted_at', 'timestamp with time zone', 'transaction_timestamp()']].map do |name, type, default|
      { 'attname' => name, 'type' => type, 'required' => 'true', 'default_value' => default, 'attidentity' => '', 'attgenerated' => '' }
    end
    raise Invalid unless rows == expected
  end

  def verify_constraints!
    rows = @connection.exec_params(<<~SQL.squish, [Definition::TABLE]).to_a
      SELECT x.conname, x.contype, x.convalidated, x.condeferrable, x.condeferred, pg_get_constraintdef(x.oid,true) AS definition
      FROM pg_constraint x JOIN pg_class c ON c.oid=x.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='public' AND c.relname=$1 ORDER BY x.conname
    SQL
    checks = { 'toybaco_durable_acceptance_name' => ['c', "CHECK (#{Definition.acceptance_check(@names)})"],
               'toybaco_durable_acceptance_pk' => ['p', 'PRIMARY KEY (capability)'],
               'toybaco_durable_acceptance_time' => ['c', 'CHECK (isfinite(accepted_at))'] }
    raise Invalid unless rows.size == checks.size

    rows.each { |row| verify_constraint!(row, checks.fetch(row.fetch('conname'))) }
    verify_index!
  rescue KeyError
    raise Invalid
  end

  def verify_constraint!(row, expected)
    raise Invalid unless row.values_at('contype', 'convalidated', 'condeferrable', 'condeferred') == [expected[0], 't', 'f', 'f'] &&
                         row.fetch('definition').delete("\n ()") == expected[1].delete("\n ()")
  end

  def verify_index!
    rows = @connection.exec_params(<<~SQL.squish, [Definition::TABLE]).to_a
      SELECT i.indisunique, i.indisprimary, i.indisvalid, i.indisready, pg_get_indexdef(i.indexrelid) AS definition
      FROM pg_index i JOIN pg_class c ON c.oid=i.indrelid JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='public' AND c.relname=$1
    SQL
    expected = "CREATE UNIQUE INDEX toybaco_durable_acceptance_pk ON public.#{Definition::TABLE} USING btree (capability)"
    raise Invalid unless rows == [{ 'indisunique' => 't', 'indisprimary' => 't', 'indisvalid' => 't', 'indisready' => 't', 'definition' => expected }]
  end

  def verify_functions!
    { Definition::RECORDER => Definition::RECORDER_BODY, Definition::IMMUTABLE => Definition::IMMUTABLE_BODY }.each do |name, body|
      rows = @connection.exec_params(<<~SQL.squish, [name]).to_a
        SELECT p.prosrc, l.lanname, p.prorettype::regtype::text AS returns, p.pronargs::text AS arguments,
          p.provolatile, p.prosecdef, p.proleakproof, p.proconfig::text AS config,
          pg_get_userbyid(p.proowner) = current_user AS owned
        FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace JOIN pg_language l ON l.oid=p.prolang
        WHERE n.nspname='public' AND p.proname=$1
      SQL
      expected = { 'prosrc' => "\n#{body}", 'lanname' => 'plpgsql', 'returns' => 'trigger', 'arguments' => '0', 'provolatile' => 'v',
                   'prosecdef' => 'f', 'proleakproof' => 'f', 'config' => '{"search_path=pg_catalog, public"}', 'owned' => 't' }
      raise Invalid unless rows == [expected]
    end
  end

  def verify_triggers!
    names = PG::TextEncoder::Array.new.encode([Definition::RECORDER, Definition::IMMUTABLE])
    rows = @connection.exec_params(<<~SQL.squish, [names]).to_a
      SELECT t.tgname, c.relname AS table_name, p.proname AS function_name, t.tgtype::text AS type,
        encode(t.tgargs,'hex') AS arguments, t.tgenabled, t.tgisinternal, t.tgattr::text AS columns,
        t.tgqual IS NULL AS unconditional, t.tgconstraint::text AS constraint_id
      FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace
      JOIN pg_proc p ON p.oid=t.tgfoid JOIN pg_namespace pn ON pn.oid=p.pronamespace
      WHERE n.nspname='public' AND ((pn.nspname='public' AND p.proname=ANY($1::text[]))
        OR c.relname='#{Definition::TABLE}')
      ORDER BY c.relname, t.tgname
    SQL
    expected = Definition.triggers(@names, extensions: @extensions).map { |row| expected_trigger(row) }
    expected.sort_by! { |row| row.values_at('table_name', 'tgname') }
    raise Invalid unless rows == expected
  end

  def expected_trigger(row)
    arguments = row.fetch(:args).map { |value| "#{value}\0" }.join.unpack1('H*')
    { 'tgname' => row.fetch(:name), 'table_name' => row.fetch(:table), 'function_name' => row.fetch(:function),
      'type' => row.fetch(:type).to_s, 'arguments' => arguments, 'tgenabled' => 'O', 'tgisinternal' => 'f',
      'columns' => '', 'unconditional' => 't', 'constraint_id' => '0' }
  end
end
