# frozen_string_literal: true

require 'time'
require_relative '../postiz_sync'
require_relative 'retention_plan'
require_relative 'retention_state'
require_relative 'posting_authority_inventory'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # The baseline reads no post body. The optional authority extension hashes
    # its exact saved payload in RAM in this separate read-only Postiz snapshot.
    class RetentionInventory
      MAX_ROWS = 10_000
      INTEGRATIONS = <<~SQL.squish.freeze
        SELECT id, name, "createdAt" AS created_at FROM "Integration"
        WHERE "organizationId" = $1 AND "deletedAt" IS NULL
        ORDER BY "createdAt", id LIMIT 10001
      SQL
      POSTS = <<~SQL.squish.freeze
        SELECT p.id, p."integrationId" AS integration_id, p."publishDate" AS publish_at, p.state::text AS state
        FROM "Post" p JOIN "Integration" i ON i.id = p."integrationId" AND i."organizationId" = p."organizationId"
        WHERE p."organizationId" = $1 AND p."deletedAt" IS NULL AND i."deletedAt" IS NULL
          AND p."parentPostId" IS NULL AND (p.state = 'QUEUE' OR p.id IN (SELECT jsonb_array_elements_text($2::jsonb)))
        ORDER BY p."publishDate", p.id LIMIT 10001
      SQL

      def initialize(account, connector: nil, authority_context: nil, renewal_recovery: nil)
        @account = account
        @renewal_recovery = renewal_recovery&.deep_dup
        @connector = connector || -> { PG.connect(ENV.fetch('TOYBACO_POSTIZ_DATABASE_URL'), connect_timeout: 5) }
        @authority_context = PostingAuthorityInventoryRecord.context!(authority_context) if authority_context
      end

      def read
        @state = RetentionState.new(@account)
        inboxes = @account.inboxes.order(:created_at, :id).limit(MAX_ROWS + 1).pluck(:id, :name, :created_at)
        bounded!(inboxes)
        posting = posting_inventory
        rows = inboxes.map { |id, name, created| connection_row(id.to_s, name, created).merge('held' => @state.inbox_held?(id.to_s)) }
        posting.merge('inboxes' => rows)
      rescue PG::Error, KeyError, ArgumentError, InboxRetention::Invalid
        raise RetentionPlan::Invalid
      end

      private

      def connection_row(id, name, created)
        { 'id' => id, 'name' => name.to_s, 'created_at_us' => timestamp(created) }
      end

      def timestamp(value)
        # Preserve PostgreSQL microseconds; ids must only break actual ties.
        time = value.is_a?(Time) ? value : DateTime.parse(value.to_s).to_time
        (time.to_r * 1_000_000).to_i
      end

      def posting_inventory
        organization = PostizSync.deterministic_organization_id(@account.id)
        stored = PostizSync.organization_id_for(@account)
        raise RetentionPlan::Invalid if stored.present? && stored != organization

        unless PostizSync.managed?(@account)
          @state.absent!
          return { 'posting_accounts' => [], 'posts' => [] }
        end

        read_posting(organization)
      end

      def read_posting(organization)
        connection = @connector.call
        connection.exec('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY')
        connection.exec("SET LOCAL statement_timeout = '5s'")
        integrations = connection.exec_params(INTEGRATIONS, [organization]).to_a
        load_posting_state(connection, organization)
        posts = connection.exec_params(POSTS, [organization, JSON.generate(@held_posts.to_a)]).to_a
        bounded!(integrations)
        bounded!(posts)
        @authority_posts = known_authority_posts(connection, posts)
        connection.exec('COMMIT')
        { 'posting_accounts' => integrations.map { |row| integration_row(row) },
          'posts' => posts.map { |row| post_row(row) } }
      ensure
        connection&.close unless connection&.finished?
      end

      def known_authority_posts(connection, posts)
        return Set.new unless @authority_context

        unknown = posts.select do |post|
          post['state'] == 'QUEUE' &&
            (@held_posts.include?(post['id']) || @kept_posts.exclude?(post['id']) || posting_held?(post['integration_id']))
        end
        PostingAuthorityInventory.new(connection, account_id: @account.id, context: @authority_context,
                                                  posting: @posting, generation: @state.posting_generation,
                                                  renewal_recovery: @renewal_recovery).known_roots(unknown)
      end

      def load_posting_state(connection, organization)
        @posting = @state.posting(connection, organization)
        value = @posting || {}
        @kept_integrations = value.fetch('keepIntegrationIds', []).to_set
        @kept_posts = value.fetch('keepPostIds', []).to_set
        @held_posts = value.fetch('heldPostIds', []).to_set
      end

      def integration_row(row)
        connection_row(row.fetch('id'), row.fetch('name'), row.fetch('created_at')).merge('held' => posting_held?(row.fetch('id')))
      end

      def posting_held?(id)
        @posting ? @kept_integrations.exclude?(id) : false
      end

      def post_held?(id)
        @held_posts.include?(id) && @authority_posts.exclude?(id)
      end

      def post_row(row)
        held = post_held?(row.fetch('id'))
        valid = if held
                  row['state'] == 'DRAFT'
                else
                  row['state'] == 'QUEUE' && (!@posting || @authority_posts.include?(row['id']) ||
                    (@kept_posts.include?(row['id']) && !posting_held?(row['integration_id'])))
                end
        raise RetentionPlan::Invalid unless valid

        { 'id' => row.fetch('id'), 'integration_id' => row.fetch('integration_id'),
          'publish_at_us' => timestamp(row.fetch('publish_at')), 'held' => held }
      end

      def bounded!(rows)
        raise RetentionPlan::Invalid if rows.size > MAX_ROWS
      end
    end
  end
end
