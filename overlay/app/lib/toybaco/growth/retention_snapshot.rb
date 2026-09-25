# frozen_string_literal: true

require 'digest'
require 'json'
require_relative '../entitlements'
require_relative 'retention_plan'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # Internal calculation only. Callers own authorization and locking. Both
    # the owner screen and the renewal journal use this exact selection rule.
    class RetentionSnapshot
      KEY = 'toybaco_growth_retention_selection'
      VERSION = GrowthTerms::VERSION
      ORDER = %w[free light standard pro].freeze

      def initialize(account, target:, rows:)
        @account = account
        @target = target
        @rows = rows
      end

      def read
        load_target!
        saved = Entitlements.attributes(@account)[KEY]
        plan = RetentionPlan.new(inventory: @rows, limits: @limits, selected: current_selection(saved)).read
        { 'target_name' => @terms.fetch('name'), 'target' => @target, 'context' => @context, 'inventory' => @rows,
          'selected' => plan.slice(*RetentionPlan::KINDS).transform_values { |value| value.fetch('keep') },
          'plan' => plan, 'revision' => self.class.fingerprint([@context, @rows, saved]) }
      end

      def self.fingerprint(value)
        Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
      end

      def self.canonical(value)
        return value.sort.to_h.transform_values { |item| canonical(item) } if value.is_a?(Hash)
        return value.map { |item| canonical(item) } if value.is_a?(Array)

        value
      end

      private

      def load_target!
        contract = Entitlements.contract_for(@account)
        raise RetentionPlan::Invalid unless eligible_contract?(contract) && ORDER.include?(@target) &&
                                            ORDER.index(@target) < ORDER.index(contract['plan_id'])

        @terms = PlanCatalog.default.definition(@target, VERSION)
        @limits = @terms.fetch('entitlements').fetch('limits')
        attrs = Entitlements.attributes(@account)
        @context = { 'account_id' => @account.id, 'subscription_id' => attrs['toybaco_subscription_id'],
                     'source' => contract, 'target' => @terms }
      end

      def eligible_contract?(contract)
        contract && contract['plan_version'] == VERSION && contract['legacy'] != true && contract['addons'] == [] &&
          contract.dig('entitlements', 'ai_meter') == GrowthTerms::METER && ORDER.include?(contract['plan_id'])
      end

      def current_selection(saved)
        return {} unless matching_saved?(saved)

        # Reconnection/deletion never carries an old id onto another connection.
        # Keep valid preferences and fill vacancies using the documented default.
        RetentionPlan::KINDS.to_h do |kind|
          ordered = @rows.fetch(kind).sort_by { |row| [row.fetch('created_at_us'), row.fetch('id')] }.map { |row| row.fetch('id') }
          prior = saved.fetch('selected')[kind]
          raise RetentionPlan::Invalid unless prior.is_a?(Array)

          remaining = prior & ordered
          missing = prior.size - remaining.size
          [kind, remaining + (ordered - remaining).first(missing)]
        end
      end

      def matching_saved?(saved)
        saved.is_a?(Hash) && saved['context'] == @context && saved['selected'].is_a?(Hash)
      end
    end
  end
end
