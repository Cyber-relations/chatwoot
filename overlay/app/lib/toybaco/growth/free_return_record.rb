# frozen_string_literal: true

require_relative 'retention_snapshot'
require_relative 'renewal_transition'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # Immutable accounting evidence is separate from the current checkout and
    # Free period. A later purchase must not overwrite the prior closed sale.
    module FreeReturnRecord
      KEY = 'toybaco_growth_free_return'
      FIELDS = %w[version account_id transition_id returned_at free_contract source_journal posting inbox settlement purchase billing_history].freeze
      class Invalid < StandardError; end

      module_function

      def current(account)
        attrs = Entitlements.attributes(account)
        return unless attrs.key?(KEY)

        pointer = attrs[KEY]
        raise Invalid unless pointer.is_a?(Hash) && pointer.keys.sort == %w[receipt_hash returned_at transition_id]

        row = Toybaco::GrowthFreeReturn.find_by(account_id: account.id, transition_id: pointer['transition_id'])
        raise Invalid unless row && valid?(row.receipt, account.id) && pointer == reference(row.receipt)

        row.receipt
      end

      def reference(value)
        value.slice('transition_id', 'returned_at', 'receipt_hash')
      end

      def valid?(value, account_id)
        return false unless header?(value, account_id)

        value['receipt_hash'] == RetentionSnapshot.fingerprint(value.slice(*FIELDS)) &&
          valid_journal?(value) && value['free_contract'] == free_contract
      end

      def header?(value, account_id)
        value.is_a?(Hash) && value.keys.sort == (FIELDS + ['receipt_hash']).sort &&
          value['version'] == 1 && value['account_id'] == account_id && value['returned_at'].is_a?(Integer) && value['returned_at'].positive?
      end

      def valid_journal?(value)
        journal = value['source_journal']
        RenewalTransition.valid?(journal) && journal['state'] == 'provider_closed' && journal['id'] == value['transition_id'] &&
          journal.dig('binding', 'account_id') == value['account_id'] && journal['observed_at'] <= value['returned_at']
      end

      def free_contract
        terms = PlanCatalog.default.definition('free', RetentionSnapshot::VERSION)
        Entitlements.snapshot_for(terms, cycle: nil)
      end

      def completed?(account, journal)
        receipt = current(account)
        receipt && journal['state'] == 'free_completed' && journal['observed_at'] == receipt['returned_at'] &&
          journal.except('state', 'observed_at') == receipt['source_journal'].except('state', 'observed_at')
      rescue Invalid
        false
      end

      def included_allowed?(account, grant, receipt)
        return true unless receipt

        contract = Entitlements.contract_for(account)
        prefix = if contract['plan_id'] == 'free'
                   free_prefix(receipt)
                 else
                   "paid:#{Entitlements.attributes(account).fetch('toybaco_subscription_id')}:"
                 end
        grant.source_key.start_with?(prefix)
      end

      def free_prefix(receipt)
        "free:return:#{receipt.fetch('transition_id')}:"
      end
    end
  end
end
