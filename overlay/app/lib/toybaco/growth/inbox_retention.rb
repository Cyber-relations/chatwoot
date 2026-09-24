# frozen_string_literal: true

require_relative 'posting_retention'
require_relative 'inbox_release_record'
require_relative 'inbox_delivery_epoch'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # Installation is internal-only. Runtime enforcement does not depend on a
    # flag: turning a rollout flag off must never reactivate a persisted hold.
    class InboxRetention
      KEY = 'toybaco_growth_inbox_retention'
      FIELDS = %w[version account_id transition_id plan_version keep_inbox_ids posting_receipt_hash confirmed_at].freeze
      class Busy < StandardError
        def initialize = super('受信箱を処理中です。時間をおいて再度お試しください。')
      end

      class Held < StandardError
        def initialize = super('この受信箱は保留中です。入力内容を残して、契約の設定をご確認ください。')
      end

      class Invalid < StandardError
        def initialize = super('受信箱の利用状態を確認できません。')
      end

      def initialize(account, environment: ENV, clock: -> { Time.now.utc })
        @account = account
        @environment = environment
        @clock = clock
      end

      def call
        raise Invalid unless @environment['TOYBACO_INBOX_RETENTION_ENABLED'] == 'true'

        Checkout::PlanChangeLock.call(@account) do
          raise Invalid if @account.class.connection.transaction_open?

          self.class.with_fence(@account.id, exclusive: true) do
            @account.with_lock { install! }
          end
        end
      end

      # Keep the same connection for the entire operation. Model callbacks may
      # run inside an outer transaction: in that case hold a transaction lock
      # until COMMIT/ROLLBACK, not just until the callback returns.
      def self.with_fence(account_id, exclusive: false)
        Account.connection_pool.with_connection do |connection|
          # PostgreSQL functions mutate session state even though this is a
          # SELECT. Reusing a cached true/false would bypass or strand the lock.
          connection.uncached do
            transactional, mode = fence_mode(connection, exclusive)
            key = fence_key(account_id)
            scope = transactional ? '_xact' : ''
            raise Busy unless connection.select_value("SELECT pg_try_advisory#{scope}_lock#{mode}(#{key})")

            begin
              yield
            ensure
              connection.select_value("SELECT pg_advisory_unlock#{mode}(#{key})") unless transactional
            end
          end
        end
      end

      def self.fence_key(account_id)
        id = Integer(account_id)
        raise Invalid unless id.positive?

        key = Digest::SHA256.hexdigest("toybaco-inbox-retention:#{id}")[0, 16].to_i(16)
        key >= 2**63 ? key - (2**64) : key
      end

      def self.fence_mode(connection, exclusive)
        transactional = connection.transaction_open?
        raise Invalid if exclusive && transactional
        raise Invalid if transactional && connection.select_value('SHOW transaction_isolation') != 'read committed'

        [transactional, exclusive ? '' : '_shared']
      end

      def self.with_inbox(inbox, now: Time.now.utc)
        raise Invalid unless inbox&.persisted? && inbox.account_id.is_a?(Integer)

        with_fence(inbox.account_id) do
          Account.uncached { check_access!(inbox, now) }
          yield
        end
      end

      # Never trust an association cache or a previously loaded account.
      def self.check_access!(inbox, now)
        raise Invalid unless Inbox.exists?(id: inbox.id, account_id: inbox.account_id)

        attrs = current_attributes!(inbox.account_id)
        unless attrs.key?(KEY)
          raise Invalid if attrs.key?(InboxReleaseRecord::KEY)

          return
        end

        value = validate!(attrs[KEY], account_id: inbox.account_id, now: now)
        keep = InboxReleaseRecord.effective_ids(inbox.account_id, attrs, value, now: now)
        raise Held unless keep.include?(inbox.id.to_s)
      rescue InboxReleaseRecord::Invalid
        raise Invalid
      end

      def self.current_attributes!(account_id)
        row = Account.where(id: account_id).pick(:id, :internal_attributes)
        raise Invalid unless row && (row.last.nil? || row.last.is_a?(Hash))

        row.last || {}
      end

      def self.validate!(value, account_id:, now:)
        raise Invalid unless valid_header?(value, account_id)
        raise Invalid unless value['confirmed_at'].is_a?(Integer) && value['confirmed_at'].between?(0, now.to_i)
        raise Invalid unless %w[transition_id posting_receipt_hash receipt_hash].all? { |key| sha256?(value[key]) }

        validate_keep!(value['keep_inbox_ids'])
        raise Invalid unless value['receipt_hash'] == RetentionSnapshot.fingerprint(value.slice(*FIELDS))

        value
      end

      def self.valid_header?(value, account_id)
        value.is_a?(Hash) && value.keys.sort == (FIELDS + ['receipt_hash']).sort &&
          value.values_at('version', 'account_id', 'plan_version') == [1, account_id, RetentionSnapshot::VERSION]
      end

      def self.validate_keep!(keep)
        limit = PlanCatalog.default.definition('free', RetentionSnapshot::VERSION).fetch('entitlements').fetch('limits').fetch('inboxes')
        raise Invalid unless keep.is_a?(Array) && keep.size <= limit && keep == keep.uniq.sort && keep.all? { |id| inbox_id?(id) }
      end

      def self.sha256?(value)
        value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)
      end

      def self.inbox_id?(value)
        value.is_a?(String) && value.match?(/\A[1-9][0-9]{0,18}\z/) && value.to_i <= 9_223_372_036_854_775_807
      end

      private

      def install!
        fields = confirmed_policy
        attrs = Entitlements.attributes(@account)
        return previous!(attrs[KEY], fields) if same_transition?(attrs[KEY], fields)

        check_install_predecessor!(attrs, fields)

        value = fields.merge('receipt_hash' => RetentionSnapshot.fingerprint(fields))
        self.class.validate!(value, account_id: @account.id, now: @clock.call)
        # Deleted/reassigned choices require a fresh transition; never silently
        # substitute another inbox after Stripe has already been changed.
        keep = fields.fetch('keep_inbox_ids')
        current = @account.inboxes.where(id: keep).pluck(:id).map(&:to_s).sort
        raise Invalid unless current == keep

        persist_hold!(attrs, value)
        value
      end

      def persist_hold!(attrs, value)
        epochs = InboxDeliveryEpoch.install(@account, attrs, value, now: @clock.call)
        @account.update!(internal_attributes: attrs.except(InboxReleaseRecord::KEY).merge(KEY => value, InboxDeliveryEpoch::KEY => epochs))
      end

      def same_transition?(value, fields)
        value.is_a?(Hash) && value['transition_id'] == fields['transition_id']
      end

      def check_install_predecessor!(attrs, fields)
        if attrs.key?(KEY)
          verify_predecessor!(attrs, fields)
        elsif attrs.key?(InboxReleaseRecord::KEY)
          raise Invalid
        end
      end

      def verify_predecessor!(attrs, fields)
        previous = self.class.validate!(attrs[KEY], account_id: @account.id, now: @clock.call)
        InboxReleaseRecord.current(@account.id, attrs, previous, now: @clock.call)
        returned = FreeReturnRecord.current(@account)
        raise Invalid unless returned && returned['inbox'] == previous && fields['confirmed_at'] >= returned['returned_at'] &&
                             attrs['toybaco_subscription_id'] != returned.dig('source_journal', 'binding', 'subscription_id')
      rescue InboxReleaseRecord::Invalid, FreeReturnRecord::Invalid
        raise Invalid
      end

      def previous!(value, fields)
        previous = self.class.validate!(value, account_id: @account.id, now: @clock.call)
        raise Invalid unless previous.except('confirmed_at', 'receipt_hash') == fields.except('confirmed_at')

        InboxDeliveryEpoch.current(@account.id, Entitlements.attributes(@account), previous, now: @clock.call)

        previous
      end

      def confirmed_policy
        journal = RenewalTransition.new(@account, now: @clock.call, mode: @environment.fetch('TOYBACO_STRIPE_MODE')).current!
        raise Invalid unless journal['state'] == 'provider_closed'

        posting = PostingRetention.new(@account, environment: @environment, clock: @clock).confirmed!
        keep = journal.dig('retention', 'selected', 'inboxes')
        self.class.validate_keep!(keep)
        raise Invalid unless keep == journal.dig('retention', 'plan', 'inboxes', 'keep')

        { 'version' => 1, 'account_id' => @account.id, 'transition_id' => journal.fetch('id'),
          'plan_version' => RetentionSnapshot::VERSION, 'keep_inbox_ids' => keep.sort,
          'posting_receipt_hash' => posting.fetch('receipt_hash'), 'confirmed_at' => @clock.call.to_i }
      end
    end
  end
end
