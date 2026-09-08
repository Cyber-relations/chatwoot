# frozen_string_literal: true

module Toybaco::StoreFulfillment::Purchase
  def purchased_addon(parent, item_id)
    addons = Toybaco::Entitlements.contract_for(parent).fetch('addons')
    found = addons.select { |addon| addon['source'] == 'stripe' && addon['subscription_item_id'] == item_id }
    check!(found.length == 1, '購入した追加店舗の明細を特定できません。')
    addon = found.first
    terms = addon.fetch('terms')
    check!(addon['id'] == 'opt-store' && addon['quantity'] == 1 && separate_terms?(terms),
           '対応していない追加店舗の条件です。')
    addon
  end

  def separate_terms?(terms)
    terms['scope'] == 'separate_account' && terms['quantity_max'] == 1 &&
      !terms['plan_id'].to_s.empty? && !terms['plan_version'].to_s.empty?
  end

  def verified_purchase(parent, subscription, request)
    addon = purchased_addon(parent, request[:item_id])
    item = subscription_item(subscription, request[:item_id])
    contract = child_contract(addon, item, catalog: request[:catalog])
    price = item.fetch('price')
    check!(paid_item?(subscription, item['id'], price['id'], price['unit_amount']),
           'この追加明細の支払を確認できません。割引・日割り・不完全な請求は個別確認が必要です。')
    { addon: addon, item: item, contract: contract }
  end

  def subscription_item(subscription, item_id)
    items = subscription.fetch('items')
    check!(items['has_more'] != true && items['data'].is_a?(Array), '購入明細の一覧が不完全です。')
    selected = items['data'].select { |item| item['id'] == item_id }
    check!(selected.length == 1 && selected.first['quantity'] == 1, '購入明細と数量を確認できません。')
    selected.first
  end

  def child_contract(addon, item, catalog: Toybaco::PlanCatalog.default)
    terms = addon.fetch('terms')
    price = item.fetch('price')
    cycle = price.dig('recurring', 'interval')
    check!(price['id'] == addon['stripe_price_id'] && price['currency'] == 'jpy' &&
           price.dig('recurring', 'interval_count') == 1 && %w[month year].include?(cycle),
           '追加店舗のPriceと請求周期が一致しません。')
    definition = catalog.definition(terms.fetch('plan_id'), terms.fetch('plan_version'))
    check!(price['unit_amount'].is_a?(Integer) && price['unit_amount'].positive? &&
           price['unit_amount'] == definition.fetch('cycles').fetch(cycle).fetch('amount'), '追加店舗の購入版の料金を確認できません。')
    Toybaco::Entitlements.snapshot_for(definition, cycle: cycle, catalog: catalog)
  end

  # An earlier base-only paid invoice is not payment for a newly added store.
  # Inspect ALL lines for this item, including credits/proration, before accepting one.
  def paid_item?(subscription, item_id, price_id, amount)
    invoice = subscription['latest_invoice']
    return false unless paid_invoice?(invoice)

    lines = invoice['lines']
    return false unless lines.is_a?(Hash) && lines['has_more'] == false && lines['data'].is_a?(Array)

    selected = lines['data'].select { |line| line.dig('parent', 'subscription_item_details', 'subscription_item') == item_id }
    return false unless selected.length == 1

    paid_line?(selected.first, subscription['id'], price_id, amount)
  end

  def paid_invoice?(invoice)
    invoice.is_a?(Hash) && invoice['status'] == 'paid' && [0].include?(invoice['amount_remaining']) &&
      invoice['currency'] == 'jpy' && invoice['amount_paid'].is_a?(Integer) && invoice['amount_paid'].positive?
  end

  def paid_line?(line, subscription_id, price_id, amount)
    details = line.dig('parent', 'subscription_item_details')
    details['subscription'] == subscription_id && details['proration'] == false &&
      line.dig('pricing', 'price_details', 'price') == price_id && line['quantity'] == 1 && line['amount'] == amount &&
      Array(line['discount_amounts']).empty?
  end
end
