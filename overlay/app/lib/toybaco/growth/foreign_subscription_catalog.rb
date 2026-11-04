# frozen_string_literal: true

require_relative '../plan_catalog'

# 他製品の購読の自動クローズ(APP-1)の判定 4 が使う、自社の価格・商品の目印。PlanCatalog の data から直接組む
# (Checkout::Catalog::LOOKUP_KEYS は販売中の版の live だけなので使わない)。集めるもの:
# - 全ての plan の版(legacy を含む)の cycles の stripe(test と live)の lookup_key と、price_env の名前の env の値(price の id。
#   env が空か無い名前は飛ばし、その行は lookup_key だけで見る)
# - add-on の全ての版の stripe_lookup_key、optional_lookup_keys、release_candidates の ai_pack の lookup_key と price_env の値
# - 全ての版の product_name(ai_pack を含む)
# - 2026-08-26 の決済リンクの価格の lookup_key 7 つ(LEGACY_LOOKUP_KEYS)
# 読めない catalog は Unreadable にする(判定は foreign にしない): 読み込みの例外(PlanCatalog::Invalid・ENOENT・ParserError など)、
# catalog から集めた lookup_key が 0 件、cycles の下の price の行に lookup_key も price_env も無いもの。price を持たない版
# (legacy-unversioned・free)は cycles が空で price の行ではないので、この検査の外。
class Toybaco::Growth::ForeignSubscriptionCatalog
  class Unreadable < StandardError; end

  MODES = %w[test live].freeze
  # 2026-08-26 に本番へ入れた決済リンクの価格の lookup_key 7 つ(docs/stripe-billing-design.md:55-56。同じ一覧は 145-146)。
  # 決済リンクで作った旧い契約の購読の価格がこれを持つ時に、今の catalog に無い価格だからと他製品にしないため、catalog とは
  # 別に固定で持つ(standard と setup-standard は今の catalog にもある)。
  LEGACY_LOOKUP_KEYS = %w[starter standard business opt-ai opt-post setup-standard setup-business].freeze

  attr_reader :lookup_keys, :price_ids, :product_names

  def self.load(catalog: nil, environment: ENV)
    new((catalog || Toybaco::PlanCatalog.default).data, environment)
  rescue Unreadable
    raise
  rescue StandardError => e
    raise Unreadable, e.class.name
  end

  def initialize(data, environment)
    rows = price_rows(data)
    packs = pack_rows(data)
    @lookup_keys = lookup_keys_in(data, rows, packs)
    # price_env の名前は本番の task definition(infra/terraform)のどこにも無く、本番ではこの集合は空になる(price の id の照合は
    # 働かない)。自社の price の本番での守りは、lookup_key と、price・product の metadata の toybaco_ の鍵の 2 つ。
    @price_ids = (rows + packs).filter_map { |_key, env| text?(env) && environment[env].to_s.strip.presence }.to_set
    @product_names = product_names_in(data)
  end

  # その明細の price・product が自社の目印(lookup_key・price の id・product の name)に当たるか。
  def own?(price, product)
    lookup_keys.include?(price['lookup_key']) || price_ids.include?(price['id']) || product_names.include?(product['name'])
  end

  private

  # [lookup_key, price_env] の組。plan の全ての版の cycles の、test と live の両方。
  def price_rows(data)
    data.fetch('plans').values.flat_map { |plan| plan.fetch('versions').values }
        .flat_map { |terms| terms.fetch('cycles', {}).values }
        .flat_map { |price| MODES.map { |mode| reference(price.fetch('stripe').fetch(mode)) } }
  end

  def pack_rows(data)
    data.fetch('release_candidates', {}).values.filter_map { |candidate| candidate['ai_pack']&.dig('stripe') }
        .flat_map { |stripe| MODES.filter_map { |mode| stripe[mode] && reference(stripe[mode]) } }
  end

  def lookup_keys_in(data, rows, packs)
    raise Unreadable, 'price row without reference' if rows.any? { |key, env| !text?(key) && !text?(env) }

    keys = text_set(rows.map(&:first) + addon_keys(data) + optional_keys(data) + packs.map(&:first))
    raise Unreadable, 'no lookup key' if keys.empty?

    keys.merge(LEGACY_LOOKUP_KEYS)
  end

  def reference(value)
    raise Unreadable, 'stripe reference' unless value.is_a?(Hash)

    value.values_at('lookup_key', 'price_env')
  end

  def addon_keys(data)
    data.fetch('addons', {}).values.flat_map { |addon| addon.fetch('versions').values.map { |terms| terms['stripe_lookup_key'] } }
  end

  def optional_keys(data)
    data.fetch('optional_lookup_keys', {}).values.flatten
  end

  def product_names_in(data)
    versions = data.fetch('plans').values.flat_map { |plan| plan.fetch('versions').values }
    packs = data.fetch('release_candidates', {}).values.filter_map { |candidate| candidate['ai_pack'] }
    text_set((versions + packs).pluck('product_name'))
  end

  def text_set(values)
    values.select { |value| text?(value) }.to_set
  end

  def text?(value)
    value.is_a?(String) && !value.strip.empty?
  end
end
