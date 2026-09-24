# frozen_string_literal: true

require_relative 'retention_snapshot'
require_relative 'free_return_record'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # Durable intent before provider mutations. This is not a stop receipt:
    # provider_closed still blocks purchases until the actual holds and Free
    # entitlement transition have been implemented and confirmed.
    class RenewalTransition
      KEY = 'toybaco_growth_renewal_transition'
      STATES = %w[prepared invoice_voided provider_closed payment_recovered free_completed].freeze
      FAILURE_FIELDS = %w[subscription_id invoice_id first_failed_at grace_ends_at term_start term_end].freeze
      class Changed < StandardError; end

      def initialize(account, now:, mode:)
        @account = account
        @now = now
        @mode = mode
      end

      def self.pending?(account)
        attrs = Entitlements.attributes(account)
        return false unless attrs.key?(KEY)

        value = attrs[KEY]
        return true unless valid?(value)
        return false if value['state'] == 'payment_recovered'

        !FreeReturnRecord.completed?(account, value)
      end

      def self.valid?(value)
        shape?(value) &&
          value['binding'].is_a?(Hash) && value['retention'].is_a?(Hash) && value['prepared_at'].is_a?(Integer) &&
          value['observed_at'].is_a?(Integer) && value['id'] == identity(value)
      end

      def self.shape?(value)
        value.is_a?(Hash) && value['schema_version'] == 1 && STATES.include?(value['state'])
      end

      def self.identity(value)
        RetentionSnapshot.fingerprint(value.slice('schema_version', 'binding', 'retention', 'prepared_at'))
      end

      # Caller holds the account row lock. The containing transaction must
      # commit before any Stripe mutation; otherwise a crash loses the choice.
      def prepare!(inventory:)
        attrs = Entitlements.attributes(@account)
        return current! if attrs.key?(KEY) && self.class.pending?(@account)

        previous = attrs[KEY]
        raise Changed if previous && previous['binding'] == binding

        snapshot = RetentionSnapshot.new(@account, target: 'free', rows: inventory.read).read
        receipt = { 'schema_version' => 1, 'state' => 'prepared', 'binding' => binding,
                    'retention' => minimal_retention(snapshot), 'prepared_at' => @now.to_i, 'observed_at' => @now.to_i }
        save!(receipt.merge('id' => self.class.identity(receipt)))
      end

      def current!
        value = Entitlements.attributes(@account)[KEY]
        raise Changed unless self.class.valid?(value) && value['binding'] == binding

        value
      end

      def advance!(state)
        value = current!
        return value if value['state'] == state

        allowed = { 'prepared' => %w[invoice_voided payment_recovered],
                    'invoice_voided' => ['provider_closed'], 'provider_closed' => [], 'payment_recovered' => [] }
        raise Changed unless allowed.fetch(value['state']).include?(state)

        save!(value.merge('state' => state, 'observed_at' => @now.to_i))
      end

      private

      def binding
        attrs = Entitlements.attributes(@account)
        failure = attrs['toybaco_growth_renewal_failure']
        raise Changed unless failure.is_a?(Hash) && %w[test live].include?(@mode)

        { 'account_id' => @account.id, 'source' => Entitlements.contract_for(@account),
          'subscription_id' => attrs['toybaco_subscription_id'], 'customer_id' => attrs['toybaco_stripe_customer_id'],
          'failure' => failure.slice(*FAILURE_FIELDS), 'mode' => @mode }
      end

      def minimal_retention(snapshot)
        rows = snapshot.fetch('inventory')
        minimal = rows.slice(*RetentionPlan::KINDS).transform_values do |connections|
          connections.map { |row| row.slice('id', 'created_at_us') }
        end
        minimal['posts'] = rows.fetch('posts').map { |row| row.slice('id', 'integration_id', 'publish_at_us', 'held') }
        { 'target' => snapshot.fetch('context').fetch('target'), 'selected' => snapshot.fetch('selected'),
          'plan' => snapshot.fetch('plan'), 'inventory' => minimal }
      end

      def save!(receipt)
        @account.update!(internal_attributes: Entitlements.attributes(@account).merge(KEY => receipt))
        receipt
      end
    end
  end
end
