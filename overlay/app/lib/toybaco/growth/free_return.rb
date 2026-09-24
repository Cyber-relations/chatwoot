# frozen_string_literal: true

require_relative 'renewal_settlement'
require_relative 'inbox_retention'
require_relative 'purchase_intent'
require_relative 'free_return_record'
require_relative 'free_return_context'
require_relative 'free_period'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # Internal-only. Both actual hold acknowledgements and freshly confirmed
    # provider closure are prerequisites. No scheduler or public endpoint.
    class FreeReturn
      include FreeReturnContext

      def initialize(account, client:, environment: ENV, now: nil, inventory: nil)
        @account = account
        @client = client
        @environment = environment
        @clock = -> { now || Time.now.utc }
        @now = @clock.call
        @inventory = inventory
      end

      def call
        raise FreeReturnRecord::Invalid unless @environment['TOYBACO_GROWTH_FREE_RETURN_ENABLED'] == 'true'

        Checkout::PlanChangeLock.call(@account) do
          raise FreeReturnRecord::Invalid if @account.class.connection.transaction_open?

          previous = @account.with_lock { completed_receipt }
          return previous if previous

          @account.with_lock { checked_context }
          outcome = RenewalSettlement.new(@account, client: @client, environment: @environment, now: @now, inventory: @inventory).call
          raise FreeReturnRecord::Invalid unless outcome == 'closed'

          InboxRetention.with_fence(@account.id, exclusive: true) { @account.with_lock { complete! } }
        end
      end

      private

      def completed_receipt
        journal = Entitlements.attributes(@account)[RenewalTransition::KEY]
        return unless journal.is_a?(Hash) && journal['state'] == 'free_completed'

        raise FreeReturnRecord::Invalid unless FreeReturnRecord.completed?(@account, journal)

        FreeReturnRecord.current(@account)
      end

      def write_contract!(attrs, contract)
        Entitlements.assign_instagram(@account, Entitlements.effective(contract).fetch('features'))
        @account.update!(status: 'active', internal_attributes: attrs)
      end

      def complete!
        @now = @clock.call
        context = checked_context
        ensure_idle!
        receipt = build_receipt(context)
        raise FreeReturnRecord::Invalid unless FreeReturnRecord.valid?(receipt, @account.id)

        Toybaco::GrowthFreeReturn.create!(account: @account, transition_id: receipt['transition_id'], receipt: receipt)
        contract = receipt.fetch('free_contract')
        attrs = Entitlements.project_attributes(free_attributes(receipt), contract)
        write_contract!(attrs, contract)
        FreePeriod.new(@account, now: @now).refresh!
        receipt
      end
    end
  end
end
