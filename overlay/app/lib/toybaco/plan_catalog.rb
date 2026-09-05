# frozen_string_literal: true

require 'json'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  # Versioned product terms. New sales and existing contracts are resolved separately.
  class PlanCatalog
    class Invalid < StandardError; end

    PATH = File.expand_path('../../config/toybaco-plans.json', __dir__).freeze
    CYCLES = %w[month year].freeze
    STRIPE_MODES = %w[test live].freeze

    attr_reader :data

    def self.default
      @default ||= new(JSON.parse(File.read(PATH)))
    end

    def initialize(data)
      @data = Marshal.load(Marshal.dump(data))
      validate!
      deep_freeze(@data)
    end

    def sales
      data.fetch('current_versions').map { |id, version| definition(id, version) }
    end

    def definition(id, version)
      found = data.dig('plans', id.to_s, 'versions', version.to_s)
      raise Invalid, '契約プランの版を確認できません。' unless found

      found.merge('plan_id' => id.to_s, 'plan_version' => version.to_s)
    end

    def sale(id, cycle, version: nil)
      selected = data.fetch('current_versions')[id.to_s]
      raise Invalid, 'このプランは現在お申し込みいただけません。' unless selected
      raise Invalid, 'プランの条件が更新されました。内容を確認して再度お申し込みください。' if version && version != selected

      found = definition(id, selected)
      raise Invalid, 'この請求周期ではお申し込みいただけません。' unless found['sellable'] == true && found.fetch('cycles').key?(cycle.to_s)

      found
    end

    def legacy(id)
      version = data.fetch('legacy_plan_versions')[id.to_s]
      raise Invalid, '既存の契約条件を確認できません。' unless version

      definition(id, version)
    end

    def change_policy(from:, to:)
      source, target = [from, to].map { |value| value.transform_keys(&:to_s) }
      [source, target].each { |plan| validate_change_plan!(plan) }
      sale(target.fetch('plan_id'), target.fetch('cycle'), version: target.fetch('plan_version'))
      kind = change_kind(source, target)
      changes = data.fetch('plan_changes')
      changes.fetch('policies').fetch(kind).merge('kind' => kind, 'version' => changes.fetch('version'))
    rescue KeyError, NoMethodError, TypeError
      raise Invalid, 'この契約条件ではプラン変更を受け付けられません。'
    end

    def validate!
      raise Invalid, 'unsupported catalog schema' unless data['schema_version'] == 1
      raise Invalid, 'catalog currency must be JPY' unless data['currency'] == 'jpy'

      data.fetch('plans').each { |id, plan| validate_plan!(id, plan) }
      validate_sales!
      data.fetch('legacy_plan_versions').each { |id, version| definition(id, version) }
      validate_plan_changes!
      true
    rescue KeyError, NoMethodError, TypeError => e
      raise Invalid, "invalid catalog: #{e.class}"
    end

    def self.validate_entitlements!(value, complete: false)
      raise Invalid, 'invalid entitlements' unless value.is_a?(Hash)

      features = value.fetch('features')
      limits = value.fetch('limits')
      raise Invalid, 'invalid feature or limit' unless boolean_features?(features) && valid_limits?(limits)

      validate_complete_entitlements!(value) if complete
      true
    rescue KeyError
      raise Invalid, 'incomplete entitlements'
    end

    def self.boolean_features?(features)
      features.is_a?(Hash) && features.values.all? { |value| value == true || value == false }
    end

    def self.valid_limits?(limits)
      limits.is_a?(Hash) && limits.key?('agents') && limits.values.all? { |value| value.nil? || (value.is_a?(Integer) && value >= 0) }
    end

    def self.validate_complete_entitlements!(value)
      features, limits = value.values_at('features', 'limits')
      raise Invalid, 'incomplete features' unless %w[channel_instagram posting ai_reply].all? { |key| features.key?(key) }
      raise Invalid, 'incomplete limits' unless %w[agents stores ai_replies].all? { |key| limits.key?(key) }

      unless value.fetch('ai_meter') == { 'unit' => 'generated_reply', 'period' => 'calendar_month', 'timezone' => 'Asia/Tokyo' }
        raise Invalid, 'unsupported AI meter'
      end
      raise Invalid, 'AI disabled with positive quota' unless consistent_ai_quota?(features, limits)
    end

    def self.consistent_ai_quota?(features, limits)
      features['ai_reply'] != false || limits['ai_replies']&.zero?
    end

    private

    def validate_change_plan!(plan)
      id, version, cycle = plan.values_at('plan_id', 'plan_version', 'cycle')
      terms = definition(id, version)
      eligible = data.fetch('plan_changes').fetch('eligible_versions')
      return if eligible[id] == version && !terms['legacy'] && CYCLES.include?(cycle) && terms.fetch('cycles').key?(cycle)

      raise Invalid, 'この契約条件ではプラン変更を受け付けられません。'
    end

    def change_kind(source, target)
      same_plan = source.fetch('plan_id') == target.fetch('plan_id')
      same_cycle = source.fetch('cycle') == target.fetch('cycle')
      raise Invalid, '現在と同じプラン・支払周期です。' if same_plan && same_cycle

      direction = data.dig('plan_changes', 'same_cycle', source.fetch('plan_id'), target.fetch('plan_id'))
      raise Invalid, 'このプランへの変更は受け付けられません。' unless same_plan || direction

      same_cycle ? direction : 'cycle_change'
    end

    def validate_plan_changes!
      changes = data.fetch('plan_changes')
      raise Invalid, 'missing plan change policy version' if changes.fetch('version').to_s.empty?

      changes.fetch('eligible_versions').each { |id, version| definition(id, version) }
      changes.fetch('same_cycle').each do |source, targets|
        targets.each { |target, kind| validate_change_pair!(changes, source, target, kind) }
      end
      supported = [%w[after_payment invoice_difference], %w[period_end none]]
      %w[upgrade downgrade cycle_change].each do |kind|
        policy = changes.fetch('policies').fetch(kind)
        raise Invalid, 'unsupported plan change policy' unless supported.include?(policy.values_at('effective', 'proration'))
      end
    end

    def validate_change_pair!(changes, source, target, kind)
      eligible = changes.fetch('eligible_versions')
      return if source != target && eligible.key?(source) && eligible.key?(target) && %w[upgrade downgrade].include?(kind)

      raise Invalid, 'invalid explicit plan transition'
    end

    def validate_sales!
      data.fetch('current_versions').each do |id, version|
        terms = definition(id, version)
        raise Invalid, 'current plan is not sellable' unless terms['sellable'] && !terms['cycles'].empty?
      end
    end

    def validate_plan!(id, plan)
      raise Invalid, 'invalid plan id' unless id.match?(/\A[a-z][a-z0-9_-]*\z/)

      plan.fetch('versions').each do |version, terms|
        raise Invalid, 'invalid version' if version.to_s.empty? || terms['name'].to_s.empty?

        self.class.validate_entitlements!(terms.fetch('entitlements'), complete: terms['legacy'] != true)
        terms.fetch('cycles').each { |cycle, price| validate_price!(cycle, price) }
      end
    end

    def validate_price!(cycle, price)
      unless CYCLES.include?(cycle) && price['interval'] == cycle && price['amount'].is_a?(Integer) && price['amount'].positive?
        raise Invalid, 'invalid price amount or interval'
      end

      STRIPE_MODES.each { |mode| validate_stripe_reference!(price.fetch('stripe').fetch(mode)) }
    end

    def validate_stripe_reference!(reference)
      unless reference['lookup_key'].to_s.match?(/\A[a-zA-Z0-9_-]+\z/) &&
             reference['price_env'].to_s.match?(/\ATOYBACO_STRIPE_PRICE_[A-Z0-9_]+\z/)
        raise Invalid, 'missing Stripe price reference'
      end
    end

    def deep_freeze(value)
      case value
      when Hash then value.each do |key, child|
        deep_freeze(key)
        deep_freeze(child)
      end
      when Array then value.each { |child| deep_freeze(child) }
      end
      value.freeze
    end
  end
end
