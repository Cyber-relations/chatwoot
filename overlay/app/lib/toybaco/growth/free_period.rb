# frozen_string_literal: true

require_relative '../entitlements'
require_relative 'monthly_window'
require_relative 'ai_grants'
require_relative 'free_return_record'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # Lazily renew on actual use. The verified activation anchor, never a page
    # visit or OAuth reconnect, determines the period and the idempotency key.
    class FreePeriod
      def initialize(account, now: Time.now.utc)
        @account = account
        @now = now
      end

      def refresh!
        @account.with_lock do
          attrs = Entitlements.attributes(@account)
          contract = Entitlements.contract_for(@account)
          state = attrs['toybaco_growth_registration']
          receipt = FreeReturnRecord.current(@account)
          if receipt && contract&.dig('plan_id') == 'free'
            raise FreeReturnRecord::Invalid unless contract == receipt['free_contract']

            issue_return!(receipt, contract) if @account.active?
          elsif eligible?(contract, state)
            issue!(state, contract)
          end
        end
      end

      private

      def eligible?(contract, state)
        @account.active? && contract && contract['plan_id'] == 'free' && contract.dig('entitlements', 'ai_meter') == GrowthTerms::METER &&
          state.is_a?(Hash) && state['phase'] == 'active' && state['free_anchor'].is_a?(String)
      end

      def issue_return!(receipt, contract)
        period = MonthlyWindow.new(anchor: Time.at(receipt.fetch('returned_at')).utc, now: @now).current
        return unless period

        AiGrants.new(@account).issue!(source: 'included', source_key: "#{FreeReturnRecord.free_prefix(receipt)}#{period.fetch('starts_at')}",
                                      units: contract.dig('entitlements', 'limits', 'ai_generations'),
                                      starts_at: Time.at(period.fetch('starts_at')).utc, ends_at: Time.at(period.fetch('ends_at')).utc)
      end

      def issue!(state, contract)
        period = MonthlyWindow.new(anchor: Time.iso8601(state.fetch('free_anchor')), now: @now).current
        return unless period

        AiGrants.new(@account).issue!(source: 'included', source_key: "free:#{state.fetch('free_anchor')}:#{period.fetch('starts_at')}",
                                      units: contract.dig('entitlements', 'limits', 'ai_generations'),
                                      starts_at: Time.at(period.fetch('starts_at')).utc, ends_at: Time.at(period.fetch('ends_at')).utc)
      end
    end
  end
end
