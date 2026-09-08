# frozen_string_literal: true

module Toybaco::StoreFulfillment::Bindings
  BINDING_KEYS = %w[parent_account_id subscription_id subscription_item_id slot child_account_id administrator_id
                    addon_id addon_version stripe_price_id cycle unit_amount contract].freeze

  def registry(account)
    value = Toybaco::Entitlements.attributes(account).fetch(Toybaco::StoreFulfillment::REGISTRY, {})
    check!(value.is_a?(Hash), '追加店舗の対応表を確認できません。')
    value.each { |key, binding| check!(valid_binding?(account, key, binding), '追加店舗の対応表が購入元と一致しません。') }
    check!(value.values.map { |row| row.fetch('child_account_id') }.uniq.length == value.length, '同じ追加店舗に複数の明細が関連付いています。')
    value
  end

  def valid_binding?(account, key, binding)
    return false unless binding.is_a?(Hash) && binding.keys.sort == BINDING_KEYS.sort && binding['contract'].is_a?(Hash)

    valid_binding_owner?(account, binding) && valid_binding_item?(key, binding)
  end

  def valid_binding_owner?(account, binding)
    binding['parent_account_id'] == account.id && binding['child_account_id'].is_a?(Integer) &&
      binding['child_account_id'].positive? && binding['child_account_id'] != account.id &&
      binding['administrator_id'].is_a?(Integer) && binding['administrator_id'].positive? &&
      binding['subscription_id'] == Toybaco::Entitlements.attributes(account)['toybaco_subscription_id']
  end

  def valid_binding_item?(key, binding)
    key == "#{binding['subscription_item_id']}:1" && binding['slot'] == 1 && binding['addon_id'] == 'opt-store' &&
      binding['unit_amount'].is_a?(Integer) && binding['unit_amount'].positive?
  end

  def lock_accounts(parent)
    records = registry(parent)
  rescue Toybaco::StoreFulfillment::Unavailable
    lock_account_rows([parent.id]) # Broken linkage must not prevent a verified parent cancellation.
  else
    lock_account_rows(([parent.id] + records.values.map { |row| row.fetch('child_account_id') }).sort)
  end

  def lock_account_rows(ids)
    namespace = Toybaco::PostizSync::CHATWOOT_ACCOUNT_LOCK_NAMESPACE
    ids.each { |id| Account.connection.execute("SELECT pg_advisory_xact_lock(#{namespace}, #{Integer(id)})") }
    Account.where(id: ids).order(:id).lock.index_by(&:id)
  end

  def validate_child!(child, binding)
    attrs = Toybaco::Entitlements.attributes(child)
    contract = Toybaco::Entitlements.contract_for(child)
    saved_base = binding.fetch('contract').except('addons')
    actual_base = contract&.except('addons')
    check!(attrs[Toybaco::StoreFulfillment::PURCHASE] == binding && attrs['toybaco_subscription_id'].to_s.empty? && actual_base == saved_base &&
           contract.fetch('addons').all? { |addon| addon['source'] != 'stripe' }, '追加店舗の保存済み契約または対応付けが変わっています。')
  end

  def check_no_orphan!(subscription_id, item_id)
    orphan = Account.exists?(["internal_attributes -> ? ->> 'subscription_id' = ? AND internal_attributes -> ? ->> 'subscription_item_id' = ?",
                              Toybaco::StoreFulfillment::PURCHASE, subscription_id, Toybaco::StoreFulfillment::PURCHASE, item_id])
    check!(!orphan, '追加店舗側に既存の購入対応が残っています。個別に確認してください。')
  end

  def replay(parent, subscription, accounts, binding, request)
    check!(binding['administrator_id'] == request[:administrator_id], '発行済み追加店舗の管理者は差し替えできません。')
    child = accounts[binding['child_account_id']]
    check!(child, '関連する追加店舗が見つかりません。')
    validate_child!(child, binding)
    check!(child.account_users.exists?(user_id: request[:administrator_id], role: :administrator), '追加店舗の管理者所属を確認できません。')
    check!(desired_state(parent, subscription, binding, 'applied') == 'active' && child.active?,
           '追加店舗は発行済みですが、明細の支払または利用状態を個別に確認してください。')
    child
  end

  def linked_purchase?(child)
    binding = Toybaco::Entitlements.attributes(child)[Toybaco::StoreFulfillment::PURCHASE]
    return false unless binding.is_a?(Hash) && binding['parent_account_id'].is_a?(Integer)

    parent = Account.find_by(id: binding['parent_account_id'])
    return false unless parent

    registry(parent)["#{binding['subscription_item_id']}:1"] == binding && valid_child?(child, binding)
  rescue Toybaco::StoreFulfillment::Unavailable
    false
  end

  def purchase_binding(parent, child, request, purchase)
    addon, item, contract = purchase.values_at(:addon, :item, :contract)
    {
      'parent_account_id' => parent.id, 'subscription_id' => Toybaco::Entitlements.attributes(parent)['toybaco_subscription_id'],
      'subscription_item_id' => item['id'], 'slot' => 1, 'child_account_id' => child.id, 'administrator_id' => request[:administrator_id],
      'addon_id' => addon['id'], 'addon_version' => addon['version'], 'stripe_price_id' => item.dig('price', 'id'),
      'cycle' => contract['cycle'], 'unit_amount' => item.dig('price', 'unit_amount'), 'contract' => Marshal.load(Marshal.dump(contract))
    }
  end
end
