# frozen_string_literal: true

require_relative 'posting_release_source'

class Toybaco::Growth::PostingAuthoritySource < Toybaco::Growth::PostingReleaseSource
  POINTER = <<~SQL.squish.freeze
    SELECT "organizationId", "authorityId", generation::text, epoch::text, state
    FROM "ToybacoPostingAuthorityCurrent" WHERE "organizationId" = $1
  SQL
  UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  def read(owner_id:, authority_context: nil)
    super.merge('pointer_hash' => @pointer_hash)
  end

  private

  def load_posting_state(connection, organization)
    super
    rows = connection.exec_params(POINTER, [organization]).to_a
    raise Toybaco::Growth::RetentionPlan::Invalid if rows.size > 1

    @pointer_hash = rows.empty? ? nil : pointer_hash!(rows.first, organization)
  end

  def pointer_hash!(row, organization)
    record = Toybaco::Growth::PostingPreparationRecord
    valid = row['organizationId'] == organization && record.hash?(row['authorityId']) &&
            UUID.match?(row['epoch'].to_s) && /\A[1-9][0-9]{0,18}\z/.match?(row['generation'].to_s) &&
            row['generation'].to_i < 9_223_372_036_854_775_807 && %w[pending ready stale].include?(row['state'])
    raise Toybaco::Growth::RetentionPlan::Invalid unless valid

    record.digest(row.except('state'))
  end
end
