# frozen_string_literal: true

require_relative 'posting_authority_inventory_record'
require_relative 'posting_identity_snapshot'
require_relative 'posting_payload_snapshot'
require_relative 'posting_paid_upgrade_inventory'
require_relative 'posting_renewal_inventory'

# Optional extension to the old-schema reader. Classification never grants
# execution; all lookups and transient body hashing share its read-only snapshot.
class Toybaco::Growth::PostingAuthorityInventory
  Record = Toybaco::Growth::PostingAuthorityInventoryRecord
  Invalid = Record::Invalid
  OWNER = <<~SQL.squish.freeze
    SELECT u.id AS user_id, uo.id AS membership_id, uo.role::text AS role
    FROM "User" u JOIN "UserOrganization" uo ON uo."userId" = u.id
    JOIN "Organization" o ON o.id = uo."organizationId"
    WHERE u."providerName" = 'GENERIC'::"Provider" AND u."providerId" = $1 AND u.id = $2
      AND u.activated = true AND u."deletedAt" IS NULL AND uo."organizationId" = $3
      AND uo.disabled = false AND o."deletedAt" IS NULL LIMIT 2
  SQL
  TARGETS = <<~SQL.squish.freeze
    SELECT id, "internalId", "providerIdentifier", disabled, "createdAt"
    FROM "Integration" WHERE "organizationId" = $1 AND "deletedAt" IS NULL ORDER BY id LIMIT 10001
  SQL
  MARKER = /\A(?:TOYBACO_WORKFLOW_V2\|(?:ENSURE|REPLACE)\|([0-9]{13})\|([0-9a-f-]{36})\|[^|]*\|[^|]*\|[^|]*|
    TOYBACO_PUBLISH_V2\|([0-9]{13})\|([0-9a-f-]{36})\|READY)\z/x

  def initialize(connection, account_id:, context:, posting:, **options)
    @connection = connection
    @renewal_recovery = options.fetch(:renewal_recovery, nil)&.deep_dup
    @account_id = account_id
    @context = Record.context!(context)
    @posting = posting
    @generation = options.fetch(:generation)
    @now = Time.now.utc
  end

  def known_roots(posts)
    return Set.new unless readable?(posts)
    return Set.new unless load_current!

    validate_source!
    posts.select { |post| post['state'] == 'QUEUE' }.filter_map { |post| known_root(post) }.to_set
  rescue JSON::ParserError, KeyError, ArgumentError, TypeError
    raise Invalid
  end

  private

  def readable?(posts)
    @posting && posts.any? { |post| post['state'] == 'QUEUE' } && extension?
  end

  def load_current!
    @organization = @posting.fetch('organizationId')
    pointer = one('SELECT * FROM "ToybacoPostingAuthorityCurrent" WHERE "organizationId" = $1', [@organization])
    return false unless pointer

    Record.pointer!(pointer, @organization)
    return false unless pointer['state'] == 'ready' || (pointer['state'] == 'pending' && @renewal_recovery)

    @pointer = pointer

    @authority = authority(pointer)
    return false if pointer['state'] != 'ready' && %w[renewal_grace renewal_paid].exclude?(@authority['kind'])

    @request = preparation(@authority)
    current_context?
  end

  def extension?
    @connection.exec(%q{SELECT to_regclass('"ToybacoPostingAuthorityCurrent"')}).getvalue(0, 0).present?
  end

  def one(sql, arguments)
    rows = @connection.exec_params(sql, arguments).to_a
    raise Invalid if rows.size > 1

    rows.first
  end

  def authority(pointer)
    row = one('SELECT * FROM "ToybacoPostingAuthority" WHERE "organizationId" = $1 AND "authorityId" = $2',
              [@organization, pointer.fetch('authorityId')])
    raise Invalid unless row

    @authority_hash = row.fetch('authorityHash')
    Record.authority!(row, pointer)
  end

  def preparation(value)
    row = one('SELECT * FROM "ToybacoPostingPreparation" WHERE "organizationId" = $1 AND "requestId" = $2',
              [@organization, value.fetch('preparationRequestId')])
    raise Invalid unless row

    Record.preparation!(row, value, @account_id, now: @now)
  end

  def current_context?
    expected = @context.merge('holdTransitionId' => @posting.fetch('transitionId'), 'holdReceiptHash' => @posting.fetch('receiptHash'),
                              'holdGeneration' => @generation)
    actual = @request
    if %w[renewal_grace renewal_paid].include?(@authority['kind'])
      @paid_upgrade = Toybaco::Growth::PostingRenewalInventory.new(@connection, @authority, @authority_hash, @request,
                                                                   recovery: @renewal_recovery, pointer: @pointer)
      actual = actual.merge(@paid_upgrade.context)
    elsif @authority['kind'] == 'paid_upgrade'
      @paid_upgrade = Toybaco::Growth::PostingPaidUpgradeInventory.new(@connection, @authority, @authority_hash, @request)
      actual = actual.merge(@paid_upgrade.context)
    end
    actual.slice(*expected.keys) == expected
  end

  def validate_source!
    load_owner!
    targets = @connection.exec_params(TARGETS, [@organization]).to_a
    raise Invalid unless targets.size <= 10_000 && (@request['keepIntegrationIds'] - targets.pluck('id')).empty?

    validate_selection!
    subjects = [['Organization', @organization], ['User', @owner.fetch('user_id')], ['UserOrganization', @owner.fetch('membership_id')]] +
               targets.map { |row| ['Integration', row.fetch('id')] }
    raise Invalid unless Toybaco::Growth::PostingIdentitySnapshot.read(@connection, subjects) == @request['identityHash']
  end

  def load_owner!
    owner_id = @context.fetch('ownerId')
    @owner = one(OWNER, ["cw:#{owner_id}", Toybaco::PostizSync.deterministic_user_id(owner_id), @organization])
    raise Invalid unless @owner && @owner['role'] == 'ADMIN' && @owner['membership_id'] == @request['ownerMembershipId']
  end

  def validate_selection!
    kept = @posting.fetch('keepIntegrationIds')
    requested = @request.fetch('requestedIntegrationIds')
    raise Invalid if requested.intersect?(kept)
    raise Invalid unless (kept + requested).sort == @request['keepIntegrationIds']
  end

  def known_root(post)
    row = one('SELECT error FROM "Post" WHERE "organizationId" = $1 AND id = $2', [@organization, post.fetch('id')])
    raise Invalid unless row

    match = MARKER.match(row['error'].to_s)
    return unless match

    generation = match.captures.compact.join(':')
    schedule = one('SELECT * FROM "ToybacoPostingSchedule" WHERE "organizationId" = $1 AND "rootId" = $2 AND "rootGeneration" = $3',
                   [@organization, post.fetch('id'), generation])
    raise Invalid unless schedule

    value = Record.object(schedule.fetch('payload'))
    validate_schedule!(schedule, value, post, generation)
    validate_save!(value, post.fetch('id'))
    post.fetch('id')
  end

  def validate_schedule!(row, value, post, generation)
    expected = { 'rootId' => post.fetch('id'), 'organizationId' => @organization,
                 'rootGeneration' => generation, 'integrationId' => post.fetch('integration_id') }
    raise Invalid unless schedule_authority?(row, value) && Record::Record.digest(value) == row['scheduleHash'] &&
                         value.slice(*expected.keys) == expected && @request['keepIntegrationIds'].include?(value['integrationId']) &&
                         value['publishAt'] == DateTime.parse(post.fetch('publish_at')).to_time.to_r * 1000
    raise Invalid unless value['postPayloadHash'] == Toybaco::Growth::PostingPayloadSnapshot.fingerprint(@connection, @organization, post.fetch('id'))
  end

  def schedule_authority?(row, value)
    same_authority = row['authorityId'] == @authority['authorityId'] && value['authorityHash'] == @authority_hash
    same_authority ||= @paid_upgrade&.schedule?(row, value)
    same_authority
  end

  def validate_save!(value, root_id)
    saved = one('SELECT "payloadHash", "postsJson" FROM "ToybacoPostSaveRequest" WHERE "organizationId" = $1 AND "actorId" = $2 AND "requestId" = $3',
                [@organization, @owner.fetch('user_id'), value.fetch('saveRequestId')])
    raise Invalid unless saved && saved['payloadHash'] == value['savePayloadHash']

    posts = JSON.parse(saved.fetch('postsJson'), allow_duplicate_key: false, max_nesting: 16)
    raise Invalid unless posts.is_a?(Array) && posts.any? { |post| post.is_a?(Hash) && post['postId'] == root_id }
  end
end
