# frozen_string_literal: true

require_relative 'plan_catalog'
require_relative 'contract_addons'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  # Converts stored contract terms into existing Chatwoot/Postiz permissions.
  # A catalog update never silently rewrites a stored contract snapshot.
  module Entitlements
    module_function

    def attributes(account)
      raw = account.respond_to?(:internal_attributes) ? account.internal_attributes : nil
      raw.is_a?(Hash) ? raw.transform_keys(&:to_s) : {}
    end

    def contract_for(account, catalog: PlanCatalog.default)
      attrs = attributes(account)
      snapshot = attrs['toybaco_contract']
      if snapshot.is_a?(Hash)
        validate_contract!(snapshot)
        return snapshot
      end
      id = attrs['toybaco_plan'].to_s
      return nil if id.empty?

      version = attrs['toybaco_plan_version']
      terms = version ? catalog.definition(id, version) : catalog.legacy(id)
      snapshot_for(terms, cycle: attrs['toybaco_cycle'], addons: legacy_addons(attrs, terms))
    end

    def for_account(account, catalog: PlanCatalog.default)
      contract = contract_for(account, catalog: catalog)
      contract && effective(contract, catalog: catalog)
    end

    def snapshot_for(terms, cycle:, reference_price_id: nil, addons: [], catalog: PlanCatalog.default)
      raise PlanCatalog::Invalid, '契約の請求周期を確認できません。' if cycle && !valid_cycle?(cycle)

      {
        'schema_version' => 1, 'plan_id' => terms.fetch('plan_id'),
        'plan_version' => terms.fetch('plan_version'), 'name' => terms.fetch('name'),
        'cycle' => cycle, 'reference_price_id' => reference_price_id,
        'entitlements' => Marshal.load(Marshal.dump(terms.fetch('entitlements'))),
        'billing_policy' => Marshal.load(Marshal.dump(terms.fetch('billing_policy', {}))),
        'addons' => addons.map { |addon| bind_addon(addon, catalog: catalog) }, 'legacy' => terms['legacy'] == true
      }
    end

    def validate_contract!(contract)
      unless contract['schema_version'] == 1 && !contract['plan_id'].to_s.empty? &&
             !contract['plan_version'].to_s.empty? && !contract['name'].to_s.empty? &&
             valid_cycle?(contract['cycle']) &&
             contract['addons'].is_a?(Array)
        raise PlanCatalog::Invalid, '保存された契約条件を確認できません。'
      end

      PlanCatalog.validate_entitlements!(contract.fetch('entitlements'), complete: contract['legacy'] != true)
    end

    def valid_cycle?(cycle)
      cycle.nil? || %w[month year].include?(cycle)
    end

    def effective(contract, catalog: PlanCatalog.default)
      validate_contract!(contract)
      result = Marshal.load(Marshal.dump(contract.fetch('entitlements')))
      contract.fetch('addons').each do |addon|
        bound = bind_addon(addon, catalog: catalog)
        definition = bound.fetch('terms')
        next unless definition['scope'] == 'account'

        result['features'].merge!(definition.fetch('features', {}))
      end
      result
    end

    def new_addon(id, quantity:, source:, catalog: PlanCatalog.default)
      version = catalog.data.dig('addons', id, 'current_version')
      raise PlanCatalog::Invalid, '追加契約の版を確認できません。' unless version

      bind_addon({ 'id' => id, 'version' => version, 'quantity' => quantity, 'source' => source }, catalog: catalog)
    end

    def bind_addon(addon, catalog: PlanCatalog.default)
      ContractAddons.bind(addon, catalog: catalog)
    end

    def legacy_addons(attrs, terms)
      existing = attrs['toybaco_contract_addons']
      return existing if existing.is_a?(Array)
      return [] unless terms['legacy'] && !terms.dig('entitlements', 'features', 'posting') && attrs.dig('postiz', 'enabled') == true

      [{ 'id' => 'manual-posting', 'quantity' => 1, 'source' => 'legacy_manual' }]
    end

    def apply!(account, contract, subscription_id: nil, catalog: PlanCatalog.default)
      contract = contract.merge('addons' => contract.fetch('addons').map { |addon| bind_addon(addon, catalog: catalog) })
      values = effective(contract, catalog: catalog)
      account.with_lock do
        attrs = attributes(account)
        features = values.fetch('features')
        apply_instagram!(account, features) if features.key?('channel_instagram')
        updates = {
          'toybaco_plan' => contract.fetch('plan_id'),
          'toybaco_plan_version' => contract.fetch('plan_version'),
          'toybaco_cycle' => contract['cycle'], 'toybaco_contract' => contract,
          'toybaco_contract_addons' => contract.fetch('addons'),
          'postiz' => (attrs['postiz'] || {}).merge('enabled' => features['posting'] == true)
        }
        updates['toybaco_subscription_id'] = subscription_id if subscription_id
        account.update!(internal_attributes: attrs.merge(updates))
      end
      contract
    end

    def apply_instagram!(account, features)
      method = features['channel_instagram'] ? :enable_features! : :disable_features!
      account.public_send(method, 'channel_instagram')
    end
  end
end
