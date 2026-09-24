# frozen_string_literal: true

require_relative 'retention_inventory'

# Read with the authorized business rows in the same read-only snapshot. The
# fingerprint binds a non-executable preparation; tombstones grant no rights.
module Toybaco::Growth::PostingIdentitySnapshot
  Invalid = Toybaco::Growth::RetentionPlan::Invalid
  KINDS = %w[Integration Organization User UserOrganization].freeze
  MAX_GENERATION = 9_223_372_036_854_775_807
  EPOCH = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  QUERY = <<~SQL.squish.freeze
    SELECT e.kind, e."entityId", e.generation::text AS generation, e.epoch::text AS epoch
    FROM "ToybacoPostingIdentityEpoch" e
    JOIN jsonb_to_recordset($1::jsonb) AS requested(kind text, "entityId" text)
      ON e.kind = requested.kind AND e."entityId" = requested."entityId"
    ORDER BY e.kind COLLATE "C", e."entityId" COLLATE "C"
  SQL

  module_function

  def read(connection, subjects)
    requested = normalize(subjects)
    rows = connection.exec_params(QUERY, [JSON.generate(requested)]).to_a
    validate!(rows, requested)
    Toybaco::Growth::RetentionSnapshot.fingerprint(rows)
  end

  def normalize(subjects)
    raise Invalid unless subjects.is_a?(Array) && subjects.size.between?(1, 10_003)
    raise Invalid unless subjects.all? { |item| subject?(item) } && subjects.uniq.size == subjects.size

    subjects.sort.map { |kind, id| { 'kind' => kind.dup, 'entityId' => id.dup } }
  end

  def subject?(item)
    item.is_a?(Array) && item.size == 2 && KINDS.include?(item[0]) &&
      item[1].is_a?(String) && item[1].match?(/\A[A-Za-z0-9_-]{1,128}\z/)
  end

  def validate!(rows, requested)
    raise Invalid unless rows.size == requested.size

    rows.each_with_index do |row, index|
      raise Invalid unless row.keys.sort == %w[entityId epoch generation kind] && row.slice('kind', 'entityId') == requested[index]
      raise Invalid unless generation?(row['generation']) && epoch?(row['epoch'])
    end
  end

  def epoch?(value)
    value.is_a?(String) && EPOCH.match?(value)
  end

  def generation?(value)
    value.is_a?(String) && value.match?(/\A[1-9][0-9]{0,18}\z/) && value.to_i < MAX_GENERATION
  end
end
