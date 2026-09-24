# frozen_string_literal: true

require_relative '../billing_access'
require_relative '../checkout/plan_change_error'
require_relative '../checkout/plan_change_lock'
require_relative 'retention_inventory'
require_relative 'retention_snapshot'
require_relative 'renewal_transition'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # Stores an owner's preference, not a contract change or an entitlement.
    class RetentionSelection
      KEY = RetentionSnapshot::KEY
      VERSION = RetentionSnapshot::VERSION
      class Forbidden < StandardError; end
      class Changed < StandardError; end

      def initialize(account, user, target:, inventory: nil)
        @account = account
        @user = user
        @target = target
        @inventory = inventory || RetentionInventory.new(account)
      end

      def read
        Checkout::PlanChangeLock.call(@account) { public_view(snapshot) }
      end

      def held
        Checkout::PlanChangeLock.call(@account) do
          raise Forbidden unless @account.active? && BillingAccess.permissions(@account, @user)[:can_manage_billing]

          rows = @inventory.read
          counts = Hash.new(0)
          rows.fetch('posts').each { |post| counts[post.fetch('integration_id')] += 1 if post.fetch('held') }
          { 'inboxes' => rows.fetch('inboxes'),
            'posting_accounts' => rows.fetch('posting_accounts').map { |row| row.merge('held_posts' => counts[row.fetch('id')]) } }
        end
      end

      def save!(selected:, revision:)
        raise RetentionPlan::Invalid unless selected.is_a?(Hash) && selected.keys.sort == RetentionPlan::KINDS.sort

        Checkout::PlanChangeLock.call(@account) do
          @account.with_lock do
            raise Changed if RenewalTransition.pending?(@account)

            current = snapshot
            raise Changed unless revision.is_a?(String) && revision == current.fetch('revision')

            store!(current, selected)
          end
        end
      end

      private

      def store!(current, selected)
        context = current.fetch('context')
        rows = current.fetch('inventory')
        limits = context.fetch('target').fetch('entitlements').fetch('limits')
        plan = RetentionPlan.new(inventory: rows, limits: limits, selected: selected).read
        record = { 'context' => context, 'selected' => selected, 'updated_at' => Time.now.utc.iso8601 }
        @account.update!(internal_attributes: Entitlements.attributes(@account).merge(KEY => record))
        result = current.merge('plan' => plan, 'selected' => selected, 'revision' => RetentionSnapshot.fingerprint([context, rows, record]))
        public_view(result)
      end

      def snapshot
        raise Forbidden unless @account.active? && BillingAccess.permissions(@account, @user)[:can_manage_billing]

        RetentionSnapshot.new(@account, target: @target, rows: @inventory.read).read
      end

      def public_view(value)
        value.except('context').merge('inventory' => value.fetch('inventory').except('posts'))
      end
    end
  end
end
