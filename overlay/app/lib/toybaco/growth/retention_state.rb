# frozen_string_literal: true

require_relative 'inbox_retention'
require_relative 'retention_history'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # Read the same persistent fence used by delivery, including after a new
    # subscription. A contract or a rollout flag must not imply release.
    class RetentionState
      attr_reader :posting_generation

      POSTING_FIELDS = %w[organizationId transitionId policyHash receiptHash policy keepIntegrationIds keepPostIds heldPostIds].freeze
      JSON_FIELDS = %w[policy keepIntegrationIds keepPostIds heldPostIds].freeze
      POLICY_FIELDS = %w[organizationId transitionId keepIntegrationIds scheduledPostsPerAccount policyHash].freeze
      PARENT_FIELDS = %w[previousTransitionId previousReceiptHash].freeze
      SQL = <<~SQL.squish.freeze
        SELECT "organizationId", "transitionId", "policyHash", "receiptHash", policy, "keepIntegrationIds", "keepPostIds", "heldPostIds"
        FROM "ToybacoPostingRetention" WHERE "organizationId" = $1 LIMIT 2
      SQL

      def initialize(account, now: Time.now.utc)
        @account = account
        @now = now
        @attrs = InboxRetention.current_attributes!(account.id)
        @inbox = InboxRetention.validate!(@attrs[InboxRetention::KEY], account_id: account.id, now: now) if @attrs.key?(InboxRetention::KEY)
        @inbox_keep = InboxReleaseRecord.effective_ids(account.id, @attrs, @inbox, now: now)
      rescue InboxReleaseRecord::Invalid
        raise RetentionPlan::Invalid
      end

      def inbox_held?(id)
        @inbox_keep ? @inbox_keep.exclude?(id) : false
      end

      def posting(connection, organization)
        table = connection.exec(%q{SELECT to_regclass('"ToybacoPostingRetention"')}).getvalue(0, 0)
        rows = table ? connection.exec_params(SQL, [organization]).to_a : []
        raise RetentionPlan::Invalid if rows.size > 1

        value = decode(rows.first) if rows.any?
        validate!(value, organization) if value
        check_history!(connection, organization, value)
        return absent! unless value

        validate_ack!(value)
        value
      rescue JSON::ParserError, InboxRetention::Invalid
        raise RetentionPlan::Invalid
      end

      def absent!
        raise RetentionPlan::Invalid if @attrs.key?(PostingRetention::KEY) || @inbox

        nil
      end

      private

      def check_history!(connection, organization, value)
        history = RetentionHistory.new(connection, organization) { |receipt, org| validate!(receipt, org) }.check!(value)
        @posting_generation = history&.fetch('generation')
      end

      def decode(row)
        raise RetentionPlan::Invalid unless row.keys.sort == POSTING_FIELDS.sort

        row.merge(JSON_FIELDS.index_with do |name|
          JSON.parse(row.fetch(name), allow_duplicate_key: false, max_nesting: 4)
        end)
      end

      def valid_ids?(value)
        value.is_a?(Array) && value.size <= 10_000 && value.uniq == value &&
          value.all? { |id| id.is_a?(String) && id.match?(/\A[A-Za-z0-9_-]{1,128}\z/) }
      end

      def digest(value)
        Digest::SHA256.hexdigest(JSON.generate(value))
      end

      def validate!(value, organization)
        policy = value['policy']
        raise RetentionPlan::Invalid unless policy.is_a?(Hash) && [POLICY_FIELDS.sort,
                                                                   (POLICY_FIELDS + PARENT_FIELDS).sort].include?(policy.keys.sort)

        sha = policy_hash!(policy, organization)
        raise RetentionPlan::Invalid unless value['organizationId'] == organization &&
                                            value['transitionId'] == policy['transitionId'] && value['policyHash'] == sha

        validate_arrays!(value, policy)
        actual = digest([sha, value['keepIntegrationIds'], value['keepPostIds'], value['heldPostIds']])
        raise RetentionPlan::Invalid unless value['receiptHash'] == actual
      end

      def policy_hash!(policy, organization)
        limit = policy['scheduledPostsPerAccount']
        raise RetentionPlan::Invalid unless policy['organizationId'] == organization && InboxRetention.sha256?(policy['transitionId']) &&
                                            limit.is_a?(Integer) && limit.between?(0, 10_000)

        validate_parent_policy!(policy)
        sha = digest(policy.slice('organizationId', 'transitionId', 'keepIntegrationIds', 'scheduledPostsPerAccount', *PARENT_FIELDS))
        raise RetentionPlan::Invalid unless policy['policyHash'] == sha

        sha
      end

      def validate_parent_policy!(policy)
        return unless policy.key?('previousTransitionId')

        raise RetentionPlan::Invalid unless PARENT_FIELDS.all? { |field| InboxRetention.sha256?(policy[field]) } &&
                                            policy['previousTransitionId'] != policy['transitionId']
      end

      def validate_arrays!(value, policy)
        arrays = [policy['keepIntegrationIds'], *value.values_at('keepIntegrationIds', 'keepPostIds', 'heldPostIds')]
        raise RetentionPlan::Invalid unless arrays.all? { |ids| valid_ids?(ids) } &&
                                            policy['keepIntegrationIds'] == policy['keepIntegrationIds'].sort &&
                                            (value['keepIntegrationIds'] - policy['keepIntegrationIds']).empty? &&
                                            !value['keepPostIds'].intersect?(value['heldPostIds'])
      end

      def validate_ack!(value)
        ack = @attrs[PostingRetention::KEY]
        validate_posting_ack!(ack, value) if @attrs.key?(PostingRetention::KEY)
        return unless @inbox

        raise RetentionPlan::Invalid unless ack && @inbox['transition_id'] == value['transitionId'] &&
                                            @inbox['posting_receipt_hash'] == value['receiptHash']
      end

      def validate_posting_ack!(ack, value)
        valid = ack.is_a?(Hash) && ack.keys.sort == (RetentionProtocol::FIELDS + ['confirmed_at']).sort &&
                InboxRetention.sha256?(ack['request_sha256']) && ack['confirmed_at'].is_a?(Integer) && ack['confirmed_at'].between?(0, @now.to_i)
        raise RetentionPlan::Invalid unless valid

        expected = { 'version' => 1, 'organization_id' => value['organizationId'], 'transition_id' => value['transitionId'],
                     'policy_hash' => value['policyHash'], 'receipt_hash' => value['receiptHash'],
                     'kept_posts' => value['keepPostIds'].size, 'held_posts' => value['heldPostIds'].size }
        raise RetentionPlan::Invalid unless ack.slice(*expected.keys) == expected
      end
    end
  end
end
