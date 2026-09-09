# frozen_string_literal: true

require_relative 'store_fulfillment'

module Toybaco::BillingAccess
  OWNER_KEY = 'toybaco_billing_owner_user_id'

  module_function

  def permissions(account, user, membership: nil)
    membership ||= account.account_users.find_by(user_id: user.id) if user
    allowed = membership && user && membership.account_id == account.id &&
              membership.user_id == user.id && owner?(account, user)
    { can_view_billing: !!allowed, can_manage_billing: !!(allowed && membership.administrator?) }
  end

  def can_view?(account, user)
    permissions(account, user).fetch(:can_view_billing)
  end

  def owner?(account, user)
    return false unless user && valid_owner_id(user.id)

    attrs = Toybaco::Entitlements.attributes(account)
    return valid_owner_id(attrs[OWNER_KEY]) == user.id unless attrs.key?(Toybaco::StoreFulfillment::PURCHASE)

    parent = purchase_parent(account, attrs[Toybaco::StoreFulfillment::PURCHASE])
    return false unless parent

    parent_owner = valid_owner_id(Toybaco::Entitlements.attributes(parent)[OWNER_KEY])
    return false unless parent_owner == user.id && parent.account_users.exists?(user_id: user.id)
    return false if attrs.key?(OWNER_KEY) && valid_owner_id(attrs[OWNER_KEY]) != parent_owner

    true
  end

  def valid_owner_id(value)
    value if value.is_a?(Integer) && value.positive?
  end

  def purchase_parent(account, binding)
    return unless binding.is_a?(Hash) && binding['child_account_id'] == account.id
    return unless valid_owner_id(binding['parent_account_id']) && binding['parent_account_id'] != account.id

    parent = Account.find_by(id: binding['parent_account_id'])
    return unless parent && !Toybaco::Entitlements.attributes(parent).key?(Toybaco::StoreFulfillment::PURCHASE)
    return unless Toybaco::StoreFulfillment.registry(parent)["#{binding['subscription_item_id']}:1"] == binding
    return unless Toybaco::StoreFulfillment.valid_child?(account, binding)

    parent
  rescue Toybaco::StoreFulfillment::Unavailable, Toybaco::PlanCatalog::Invalid, KeyError
    nil
  end
end

module Toybaco::BillingAccess::EnterpriseControllerGuard
  def self.prepended(base)
    base.before_action :require_toybaco_billing_owner,
                       only: %i[checkout subscription select_billing_currency toggle_deletion topup_checkout topup_options]
  end

  private

  def require_toybaco_billing_owner
    response.headers['Cache-Control'] = 'no-store'
    access = Toybaco::BillingAccess.permissions(@account, current_user, membership: @current_account_user)
    head :forbidden unless access.fetch(:can_manage_billing)
  end
end
