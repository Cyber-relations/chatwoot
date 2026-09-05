# frozen_string_literal: true

require_relative 'plan_catalog'

module Toybaco::ContractAddons
  SCOPES = %w[account separate_account service].freeze

  module_function

  def bind(addon, catalog:)
    raise Toybaco::PlanCatalog::Invalid, '追加契約の数量を確認できません。' unless valid_quantity?(addon)

    version = addon['version'] || catalog.data.fetch('legacy_addon_versions')[addon['id']]
    terms = addon['terms'] || catalog.data.dig('addons', addon['id'], 'versions', version)
    raise Toybaco::PlanCatalog::Invalid, '追加契約の条件を確認できません。' unless version && valid_terms?(terms)

    raise Toybaco::PlanCatalog::Invalid, '追加契約の数量が上限を超えています。' if above_maximum?(addon, terms)

    Marshal.load(Marshal.dump(addon.merge('version' => version, 'terms' => terms)))
  end

  def valid_terms?(terms)
    terms.is_a?(Hash) && SCOPES.include?(terms['scope']) && Toybaco::PlanCatalog.boolean_features?(terms.fetch('features', {}))
  end

  def valid_quantity?(addon)
    addon.is_a?(Hash) && addon['quantity'].is_a?(Integer) && addon['quantity'].positive?
  end

  def above_maximum?(addon, terms)
    terms['quantity_max'] && addon['quantity'] > terms['quantity_max']
  end
end
