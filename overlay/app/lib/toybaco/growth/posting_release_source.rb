# frozen_string_literal: true

require_relative 'retention_inventory'
require_relative 'posting_identity_snapshot'

# The inherited reader verifies held roots and current/parent history in one
# read-only Postiz snapshot. This snapshot grants no execution permission.
class Toybaco::Growth::PostingReleaseSource < Toybaco::Growth::RetentionInventory
  TARGETS = <<~SQL.squish.freeze
    SELECT id, "internalId", "providerIdentifier", disabled, "createdAt"
    FROM "Integration" WHERE "organizationId" = $1 AND "deletedAt" IS NULL ORDER BY id LIMIT 10001
  SQL
  OWNER = <<~SQL.squish.freeze
    SELECT u.id AS user_id, uo.id AS membership_id, uo.role::text AS role
    FROM "User" u JOIN "UserOrganization" uo ON uo."userId" = u.id
    JOIN "Organization" o ON o.id = uo."organizationId"
    WHERE u."providerName" = 'GENERIC'::"Provider" AND u."providerId" = $1 AND u.id = $2
      AND u.activated = true AND u."deletedAt" IS NULL AND uo."organizationId" = $3
      AND uo.disabled = false AND o."deletedAt" IS NULL
    LIMIT 2
  SQL

  def read(owner_id:)
    raise Toybaco::Growth::RetentionPlan::Invalid unless owner_id.is_a?(Integer) && owner_id.positive?

    @owner_id = owner_id
    @state = Toybaco::Growth::RetentionState.new(@account)
    inventory = posting_inventory
    raise Toybaco::Growth::RetentionPlan::Invalid unless @posting && @postiz_owner

    ids = inventory.fetch('posting_accounts').pluck('id').sort
    keep = @posting.fetch('keepIntegrationIds').sort
    raise Toybaco::Growth::RetentionPlan::Invalid unless (keep - ids).empty?

    { 'organization_id' => @posting.fetch('organizationId'), 'transition_id' => @posting.fetch('transitionId'),
      'receipt_hash' => @posting.fetch('receiptHash'), 'generation' => @state.posting_generation,
      'owner' => @postiz_owner, 'keep_ids' => keep, 'available_ids' => ids, 'identity_hash' => @identity_hash,
      'inventory_hash' => Toybaco::Growth::RetentionSnapshot.fingerprint([@posting, inventory.fetch('posts'), @targets]) }
  rescue PG::Error, KeyError, ArgumentError, Toybaco::Growth::InboxRetention::Invalid
    raise Toybaco::Growth::RetentionPlan::Invalid
  end

  private

  def load_posting_state(connection, organization)
    super
    rows = connection.exec_params(OWNER, ["cw:#{@owner_id}", Toybaco::PostizSync.deterministic_user_id(@owner_id), organization]).to_a
    raise Toybaco::Growth::RetentionPlan::Invalid unless rows.one? && rows.first['role'] == 'ADMIN'

    @postiz_owner = rows.first
    @targets = connection.exec_params(TARGETS, [organization]).to_a
    bounded!(@targets)
    subjects = [['Organization', organization], ['User', @postiz_owner.fetch('user_id')],
                ['UserOrganization', @postiz_owner.fetch('membership_id')]] + @targets.map { |row| ['Integration', row.fetch('id')] }
    @identity_hash = Toybaco::Growth::PostingIdentitySnapshot.read(connection, subjects)
  end
end
