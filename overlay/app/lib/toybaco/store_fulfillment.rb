# frozen_string_literal: true

require 'digest'
require_relative 'subscription_sync'

# Operator fulfillment and webhook reconciliation share the subscription lock.
module Toybaco::StoreFulfillment
  class Unavailable < StandardError; end
  REGISTRY = 'toybaco_store_fulfillments'
  PURCHASE = 'toybaco_store_purchase'
  SUSPENDED = 'toybaco_store_suspended'

  module_function

  def check!(condition, message)
    raise Unavailable, message unless condition
  end

  def locked(parent, subscription_id:, administrator_id: nil)
    check!(subscription_id.to_s.match?(/\Asub_[A-Za-z0-9]+\z/), '契約の参照が不正です。')
    Account.transaction do
      connection = Account.connection
      key = Digest::SHA256.digest("toybaco:provision:#{subscription_id}").unpack1('q>')
      connection.execute("SELECT pg_advisory_xact_lock(#{key})")
      if administrator_id
        namespace = Toybaco::PostizSync::CHATWOOT_USER_LOCK_NAMESPACE
        connection.execute("SELECT pg_advisory_xact_lock(#{namespace}, #{Integer(administrator_id)})")
      end
      parent.reload
      check!(Toybaco::Entitlements.attributes(parent)['toybaco_subscription_id'] == subscription_id &&
             !Toybaco::Entitlements.attributes(parent).key?(PURCHASE), '購入元の店舗と契約が一致しません。')
      yield lock_accounts(parent)
    end
  end

  def synchronize(parent, subscription_id:, client:, administrator_id: nil)
    locked(parent, subscription_id: subscription_id, administrator_id: administrator_id) do |accounts|
      Toybaco::SubscriptionSync.new(client: client).call(parent, subscription_id: subscription_id) do |subscription, outcome|
        reconcile(parent, accounts, subscription, outcome)
        yield subscription, outcome, accounts if block_given?
      end
    end
  end

  def with_account(account_id)
    Account.transaction do
      account = lock_account_rows([Integer(account_id)]).fetch(Integer(account_id))
      yield account
    end
  end

  def fulfill(parent_id:, item_id:, administrator_id:, name:, client:)
    check!(item_id.to_s.match?(/\Asi_[A-Za-z0-9]+\z/) && !name.to_s.strip.empty?, '追加店舗の明細と名称を指定してください。')
    parent = Account.find(parent_id)
    request = { item_id: item_id, administrator_id: Integer(administrator_id), name: name.to_s.strip, catalog: Toybaco::PlanCatalog.default }
    subscription_id = Toybaco::Entitlements.attributes(parent)['toybaco_subscription_id']
    result = nil
    failure = nil
    synchronize(parent, subscription_id: subscription_id, client: client,
                        administrator_id: request[:administrator_id]) do |subscription, outcome, accounts|
      Account.transaction(requires_new: true) { result = issue(parent, subscription, outcome, accounts, request) }
    rescue Unavailable, Toybaco::PlanCatalog::Invalid => e
      failure = e # Keep a verified parent cancellation; roll back only the issuance savepoint.
    end
    raise failure if failure

    result
  end

  def issue(parent, subscription, outcome, accounts, request)
    authorize_purchase!(parent, subscription, outcome, request[:administrator_id])
    records = registry(parent)
    key = "#{request[:item_id]}:1"
    return replay(parent, subscription, accounts, records.fetch(key), request) if records.key?(key)

    check_no_orphan!(subscription['id'], request[:item_id])
    purchase = verified_purchase(parent, subscription, request)
    child = create_child(parent, request, purchase)
    binding = Toybaco::Entitlements.attributes(child).fetch(PURCHASE)
    parent.update!(internal_attributes: Toybaco::Entitlements.attributes(parent).merge(REGISTRY => records.merge(key => binding)))
    child
  end

  def authorize_purchase!(parent, subscription, outcome, administrator_id)
    check!(outcome == 'applied' && parent.active? && subscription['status'] == 'active', '支払済みの有効な購入元契約を確認できません。')
    owners = Account.where("internal_attributes ->> 'toybaco_subscription_id' = ?", subscription['id']).pluck(:id)
    check!(owners == [parent.id], '購入元の店舗が一意ではありません。')
    membership = parent.account_users.lock.find_by(user_id: administrator_id, role: :administrator)
    check!(membership, '購入元店舗の管理者を指定してください。')
  end

  def create_child(parent, request, purchase)
    contract = purchase.fetch(:contract)
    child = Account.create!(name: request[:name], locale: 'ja')
    Toybaco::Entitlements.apply!(child, contract, catalog: request[:catalog])
    binding = purchase_binding(parent, child, request, purchase)
    child.update!(internal_attributes: Toybaco::Entitlements.attributes(child).merge(PURCHASE => binding, 'toybaco_store_state' => 'active'))
    AccountUser.create!(account: child, user_id: request[:administrator_id], role: :administrator)
    child
  end
end

require_relative 'store_fulfillment/bindings'
require_relative 'store_fulfillment/purchase'
require_relative 'store_fulfillment/lifecycle'

Toybaco::StoreFulfillment.extend(
  Toybaco::StoreFulfillment::Bindings,
  Toybaco::StoreFulfillment::Purchase,
  Toybaco::StoreFulfillment::Lifecycle
)
