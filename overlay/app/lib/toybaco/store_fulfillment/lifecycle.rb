# frozen_string_literal: true

module Toybaco::StoreFulfillment::Lifecycle
  def desired_state(parent, subscription, binding, outcome)
    return 'parent_suspended' unless parent.active?

    items = subscription.dig('items', 'data')
    return 'review' unless complete_items?(subscription, items)

    found = items.select { |item| item['id'] == binding['subscription_item_id'] }
    return 'item_removed' if found.empty?
    return 'invalid_quantity' unless single_store_item?(found)

    current_payment?(subscription, found.first, binding, outcome) ? 'active' : 'review'
  end

  def complete_items?(subscription, items)
    items.is_a?(Array) && subscription.dig('items', 'has_more') != true
  end

  def single_store_item?(items)
    items.length == 1 && items.first['quantity'] == 1
  end

  def current_payment?(subscription, item, binding, outcome)
    outcome == 'applied' && item.dig('price', 'id') == binding['stripe_price_id'] && subscription['status'] == 'active' &&
      paid_item?(subscription, binding['subscription_item_id'], binding['stripe_price_id'], binding['unit_amount'])
  end

  def reconcile(parent, accounts, subscription, outcome)
    registry(parent).each_value do |binding|
      child = accounts[binding['child_account_id']]
      unless valid_child?(child, binding)
        mark_review(parent, 'child_binding')
        next
      end
      state = desired_state(parent, subscription, binding, outcome)
      if state == 'review'
        mark_review(parent, 'purchase_payment')
        next
      end
      update_child_state(child, state)
    end
  rescue Toybaco::StoreFulfillment::Unavailable
    mark_review(parent, 'registry')
  end

  def update_child_state(child, state)
    attrs = Toybaco::Entitlements.attributes(child)
    updates = { 'toybaco_store_state' => state }
    status = nil
    if state != 'active' && child.active?
      updates[Toybaco::StoreFulfillment::SUSPENDED] = true
      status = 'suspended'
    elsif state == 'active' && attrs[Toybaco::StoreFulfillment::SUSPENDED] == true
      updates[Toybaco::StoreFulfillment::SUSPENDED] = false
      status = 'active' if child.status.to_s == 'suspended'
    end
    values = { internal_attributes: attrs.merge(updates) }
    values[:status] = status if status
    child.update!(values)
  end

  def valid_child?(child, binding)
    return false unless child

    validate_child!(child, binding)
    true
  rescue Toybaco::StoreFulfillment::Unavailable, Toybaco::PlanCatalog::Invalid, KeyError
    false
  end

  def mark_review(parent, reason)
    parent.update!(internal_attributes: Toybaco::Entitlements.attributes(parent).merge('toybaco_store_review' => reason))
  end
end
