# frozen_string_literal: true

require_relative 'retention_snapshot'

# Only the digest escapes this reader. Body and attachment fields stay in RAM.
module Toybaco::Growth::PostingPayloadSnapshot
  NUMBERS = %w[delay intervalInDays].freeze
  SQL = <<~SQL.squish.freeze
    SELECT p.id, p."integrationId", p."parentPostId", p.content, p.image, p.settings,
           p.delay, p.title, p.description, p."publishDate"::text, p."intervalInDays",
           p."createdAt"::text, p."approvedSubmitForOrder"::text
    FROM "Post" p JOIN "Post" r ON r.id = $2 AND r."organizationId" = p."organizationId"
      AND r."integrationId" = p."integrationId" AND r."group" = p."group"
    WHERE p."organizationId" = $1 AND p."deletedAt" IS NULL ORDER BY p.id LIMIT 10001
  SQL

  module_function

  def fingerprint(connection, organization, root_id)
    rows = connection.exec_params(SQL, [organization, root_id]).to_a
    validate_group!(rows, root_id)
    # Prisma returns Int as JSON numbers; PG's ordinary wire decoder returns text.
    rows.each do |row|
      NUMBERS.each { |key| row[key] = Integer(row[key], 10) unless row[key].nil? }
    end
    Toybaco::Growth::RetentionSnapshot.fingerprint(rows)
  end

  def validate_group!(rows, root_id)
    roots = rows.select { |row| row['parentPostId'].nil? }
    raise Toybaco::Growth::RetentionPlan::Invalid unless rows.size.between?(1, 10_000) && roots.one? && roots.first['id'] == root_id

    validate_parents!(rows)
  end

  def validate_parents!(rows)
    ids = rows.pluck('id').to_set
    raise Toybaco::Growth::RetentionPlan::Invalid unless rows.all? { |row| row['parentPostId'].nil? || ids.include?(row['parentPostId']) }
  end
end
