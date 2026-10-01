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
    # After a Free return and a new purchase, the next stop names the returned
    # hold as its Postiz predecessor and may only narrow it. The returned
    # acknowledgement stays in its Free return receipt; the saved one is
    # replaced only by this transition's acknowledgement.
    class PostingRetention
      KEY = 'toybaco_growth_posting_retention'
      PARENT = { 'previousTransitionId' => 'previous_transition_id', 'previousReceiptHash' => 'previous_receipt_hash' }.freeze

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
      # the acknowledged policy for the subsequent inbox/Free transition. The
      # returned generation is never this transition's acknowledgement.
      def confirmed!
        _, value = checked(RetentionProtocol.configuration(@environment))
        raise RenewalTransition::Changed unless value

        value
      end

      private

      def checked_payload(config)
        checked(config).first
      end

      # The request and this transition's saved acknowledgement, if any.
      def checked(config)
        payload, returned = policy_request(config)
        previous = saved(returned)
        return [payload, nil] unless previous

        RetentionProtocol.validate_response!(previous.except('confirmed_at'), payload)
        [payload, previous]
      end

      # Nothing saved yet, or still the returned generation exactly as its Free return
      # receipt recorded it (this stop replaces it). Otherwise the saved value must be
      # a confirmed acknowledgement, which the caller binds to this request.
      def saved(returned)
        attrs = Entitlements.attributes(@account)
        return unless attrs.key?(KEY)
        return if returned && attrs[KEY] == returned.fetch('posting')

        previous = attrs[KEY]
        raise RenewalTransition::Changed unless previous.is_a?(Hash) && previous['confirmed_at'].is_a?(Integer) &&
                                                previous['confirmed_at'].between?(0, @clock.call.to_i)

        previous
      end

      def journal!
        value = RenewalTransition.new(@account, now: @clock.call, mode: @environment.fetch('TOYBACO_STRIPE_MODE')).current!
        raise RenewalTransition::Changed unless value['state'] == 'provider_closed'

        value
      end

      def request_payload(config)
        policy_request(config).first
      end

      def policy_request(config)
        value = journal!
        target = PlanCatalog.default.definition('free', RetentionSnapshot::VERSION)
        raise RenewalTransition::Changed unless value.dig('retention', 'target') == target

        organization = organization!
        returned = returned_generation(value)
        keep = value.dig('retention', 'selected', 'posting_accounts')
        limits = target.fetch('entitlements').fetch('limits')
        validate_keep!(keep, limits, value, returned)
        policy = { 'organizationId' => organization, 'transitionId' => value.fetch('id'),
                   'keepIntegrationIds' => keep.sort, 'scheduledPostsPerAccount' => limits.fetch('scheduled_posts_per_account') }
        [request(policy.merge(parent(returned)), config), returned]
      end

      # The optional parent pair ends the wire body; the hash covers the policy in
      # Postiz key order (the same six keys RetentionState verifies).
      def request(policy, config)
        { 'version' => 1, 'account_id' => @account.id, 'organization_id' => policy.fetch('organizationId'),
          'transition_id' => policy.fetch('transitionId'), 'keep_integration_ids' => policy.fetch('keepIntegrationIds'),
          'scheduled_posts_per_account' => policy.fetch('scheduledPostsPerAccount'),
          'policy_hash' => Digest::SHA256.hexdigest(JSON.generate(policy)), 'issuer' => config.fetch(:issuer),
          'audience' => config.fetch(:origin) }.merge(policy.slice(*PARENT.keys).transform_keys(PARENT))
      end

      # The Free return this store came back from, when this stop belongs to a later
      # subscription (the inbox predecessor rule). Its acknowledged hold is the Postiz
      # generation this stop replaces. The receipt is the latest immutable row, which the
      # current pointer must reference. A completed return without its pointer stops here,
      # before HTTP: a guessed parent could replace the Postiz generation irreversibly.
      def returned_generation(journal)
        row = Toybaco::GrowthFreeReturn.where(account_id: @account.id).order(:id).last
        return unless row

        returned = row.receipt
        raise RenewalTransition::Changed unless FreeReturnRecord.valid?(returned, @account.id) && current_return?(returned) &&
                                                replaceable?(returned, journal)

        returned
      end

      def current_return?(returned)
        Entitlements.attributes(@account).key?(FreeReturnRecord::KEY) && FreeReturnRecord.current(@account) == returned
      rescue FreeReturnRecord::Invalid
        false
      end

      # Another transition of an earlier subscription, holding its own acknowledgement.
      def replaceable?(returned, journal)
        ack = returned['posting']
        subscription = Entitlements.attributes(@account)['toybaco_subscription_id']
        returned['transition_id'] != journal['id'] && ack.is_a?(Hash) && ack['transition_id'] == returned['transition_id'] &&
          digest?(ack['receipt_hash']) && subscription != returned.dig('source_journal', 'binding', 'subscription_id')
      end

      def parent(returned)
        return {} unless returned

        ack = returned.fetch('posting')
        { 'previousTransitionId' => ack.fetch('transition_id'), 'previousReceiptHash' => ack.fetch('receipt_hash') }
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

      def digest?(value)
        value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)
      end

      def validate_keep!(keep, limits, value, returned)
        raise RenewalTransition::Changed unless valid_ids?(keep) && keep.size <= limits.fetch('posting_accounts')

        planned = value.dig('retention', 'plan', 'posting_accounts', 'keep')
        raise RenewalTransition::Changed unless keep == planned

        narrowed!(keep, limits, returned) if returned
      end

      # Postiz refuses to widen the returned hold: its posting accounts and per-account
      # queue, as the returned journal requested them. The same rule stops before HTTP.
      def narrowed!(keep, limits, returned)
        previous = returned.dig('source_journal', 'retention', 'selected', 'posting_accounts')
        limit = returned.dig('source_journal', 'retention', 'target', 'entitlements', 'limits', 'scheduled_posts_per_account')
        raise RenewalTransition::Changed unless valid_ids?(previous) && (keep - previous).empty? && limit.is_a?(Integer) &&
                                                limits.fetch('scheduled_posts_per_account') <= limit
      end

      def persist!(payload, receipt, config)
        current, previous = checked(config)
        raise RenewalTransition::Changed unless current == payload
        raise RenewalTransition::Changed if previous && previous.except('confirmed_at') != receipt

        stored = previous || receipt.merge('confirmed_at' => @clock.call.to_i)
        @account.update!(internal_attributes: Entitlements.attributes(@account).merge(KEY => stored))
        stored
      end
    end
  end
end
