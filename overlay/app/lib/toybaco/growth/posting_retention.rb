# frozen_string_literal: true

require_relative '../checkout/plan_change_error'
require_relative '../checkout/plan_change_lock'
require_relative '../postiz_sync'
require_relative 'renewal_transition'
require_relative 'retention_transport'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # Internal-only until inbox stops, Free and repurchase are integrated. A
    # committed provider_closed journal is mandatory, even for an empty policy.
    class PostingRetention
      KEY = 'toybaco_growth_posting_retention'

      def initialize(account, environment: ENV, transport: nil, clock: -> { Time.now.utc })
        @account = account
        @environment = environment
        @clock = clock
        @transport = transport || RetentionTransport.new(environment: environment, clock: clock)
      end

      def call
        config = RetentionProtocol.configuration(@environment)
        Checkout::PlanChangeLock.call(@account) do
          raise RenewalTransition::Changed if @account.class.connection.transaction_open?

          payload = @account.with_lock { checked_payload(config) }
          receipt = @transport.call(payload)
          RetentionProtocol.validate_response!(receipt, payload)
          @account.with_lock { persist!(payload, receipt, config) }
        end
      end

      # Caller holds the billing/account locks. No HTTP is made while checking
      # the acknowledged policy for the subsequent inbox/Free transition.
      def confirmed!
        checked_payload(RetentionProtocol.configuration(@environment))
        value = Entitlements.attributes(@account)[KEY]
        raise RenewalTransition::Changed unless value

        value
      end

      private

      def checked_payload(config)
        payload = request_payload(config)
        attrs = Entitlements.attributes(@account)
        return payload unless attrs.key?(KEY)

        previous = attrs[KEY]

        raise RenewalTransition::Changed unless previous.is_a?(Hash) && previous['confirmed_at'].is_a?(Integer) &&
                                                previous['confirmed_at'].between?(0, @clock.call.to_i)

        RetentionProtocol.validate_response!(previous.except('confirmed_at'), payload)
        payload
      end

      def journal!
        value = RenewalTransition.new(@account, now: @clock.call, mode: @environment.fetch('TOYBACO_STRIPE_MODE')).current!
        raise RenewalTransition::Changed unless value['state'] == 'provider_closed'

        value
      end

      def request_payload(config)
        value = journal!
        target = PlanCatalog.default.definition('free', RetentionSnapshot::VERSION)
        raise RenewalTransition::Changed unless value.dig('retention', 'target') == target

        organization = organization!

        keep = value.dig('retention', 'selected', 'posting_accounts')
        limits = target.fetch('entitlements').fetch('limits')
        validate_keep!(keep, limits, value)
        policy = { 'organizationId' => organization, 'transitionId' => value.fetch('id'),
                   'keepIntegrationIds' => keep.sort, 'scheduledPostsPerAccount' => limits.fetch('scheduled_posts_per_account') }
        { 'version' => 1, 'account_id' => @account.id, 'organization_id' => organization, 'transition_id' => value.fetch('id'),
          'keep_integration_ids' => keep.sort, 'scheduled_posts_per_account' => policy.fetch('scheduledPostsPerAccount'),
          'policy_hash' => Digest::SHA256.hexdigest(JSON.generate(policy)), 'issuer' => config.fetch(:issuer), 'audience' => config.fetch(:origin) }
      end

      def organization!
        organization = PostizSync.deterministic_organization_id(@account.id)
        stored = PostizSync.organization_id_for(@account)
        raise RenewalTransition::Changed if stored.present? && stored != organization

        organization
      end

      def valid_ids?(keep)
        keep.is_a?(Array) && keep.uniq == keep && keep.all? { |id| id.is_a?(String) && id.match?(/\A[A-Za-z0-9_-]{1,128}\z/) }
      end

      def validate_keep!(keep, limits, value)
        raise RenewalTransition::Changed unless valid_ids?(keep) && keep.size <= limits.fetch('posting_accounts')

        planned = value.dig('retention', 'plan', 'posting_accounts', 'keep')
        raise RenewalTransition::Changed unless keep == planned
      end

      def persist!(payload, receipt, config)
        raise RenewalTransition::Changed unless checked_payload(config) == payload

        attrs = Entitlements.attributes(@account)
        previous = attrs[KEY]
        raise RenewalTransition::Changed if previous && previous.except('confirmed_at') != receipt

        stored = previous || receipt.merge('confirmed_at' => @clock.call.to_i)
        @account.update!(internal_attributes: attrs.merge(KEY => stored))
        stored
      end
    end
  end
end
