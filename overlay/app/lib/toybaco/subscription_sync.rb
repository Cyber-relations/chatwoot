# frozen_string_literal: true

require_relative 'entitlements'
require_relative 'checkout'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  # Webhooks carry a subscription ID, never authoritative plan or access state.
  # Read the latest Stripe object under the account lock so retries/old events
  # cannot overwrite a newer contract with their stale payload.
  class SubscriptionSync
    class Unresolved < StandardError; end

    def initialize(client:, catalog: PlanCatalog.default)
      @client = client
      @catalog = catalog
    end

    def call(account, subscription_id:)
      outcome = nil
      account.with_lock do
        attrs = Entitlements.attributes(account)
        raise Unresolved, 'subscription does not belong to account' unless attrs['toybaco_subscription_id'] == subscription_id

        subscription = retrieve_subscription(subscription_id)
        previous = previous_contract(account)
        contract, outcome = apply_contract(account, subscription, previous)
        apply_status(account, subscription, contract, outcome)
      end
      outcome
    end

    def resolve(subscription, previous:)
      items = subscription_items(subscription)
      saved_addon = addon_resolver(previous)
      item = base_item(items, saved_addon)
      price = item.fetch('price')
      cycle = price.dig('recurring', 'interval')
      validate_base_price!(price)
      contract = contract_for_price(price, previous, cycle)
      contract.merge('cycle' => cycle, 'stripe_price_id' => price.fetch('id'), 'subscription_item_id' => item.fetch('id'),
                     'addons' => resolved_addons(items, previous, saved_addon))
    rescue KeyError, Checkout::Error, NoMethodError
      raise Unresolved, 'subscription price has no verified contract terms'
    end

    private

    def subscription_items(subscription)
      items = subscription.dig('items', 'data')
      raise Unresolved, 'subscription items missing' unless items.is_a?(Array) && !items.empty?

      items
    end

    def addon_resolver(previous)
      existing = previous_addons(previous).select { |addon| addon['source'] == 'stripe' }
      ->(item) { existing.find { |addon| addon['stripe_price_id'] == item.dig('price', 'id') } }
    end

    def resolved_addons(items, previous, saved_addon)
      manual = previous_addons(previous).reject { |addon| addon['source'] == 'stripe' }
      purchased = items.filter_map { |item| purchased_addon(item, saved_addon.call(item)) }
      manual + purchased
    end

    def retrieve_subscription(id)
      subscription = @client.retrieve_subscription(id)
      unless subscription.is_a?(Hash) && subscription['id'] == id && subscription.dig('items', 'has_more') != true
        raise Unresolved, 'incomplete subscription response'
      end

      subscription
    end

    def previous_contract(account)
      Entitlements.contract_for(account, catalog: @catalog)
    rescue PlanCatalog::Invalid
      nil
    end

    def apply_contract(account, subscription, previous)
      contract = resolve(subscription, previous: previous)
      Entitlements.apply!(account, contract, subscription_id: subscription.fetch('id'), catalog: @catalog)
      [contract, 'applied']
    rescue Unresolved, PlanCatalog::Invalid
      [previous, 'needs_review']
    end

    def previous_addons(previous)
      previous ? previous.fetch('addons') : []
    end

    def base_item(items, saved_addon)
      base_items = items.reject { |item| saved_addon.call(item) || addon_for_price(item['price']) }
      raise Unresolved, 'base subscription item is ambiguous' unless base_items.length == 1
      raise Unresolved, 'base quantity is unsupported' unless base_items.first['quantity'] == 1

      base_items.first
    end

    def validate_base_price!(price)
      unless price['id'].to_s.match?(/\Aprice_[A-Za-z0-9]+\z/) && valid_base_amount?(price) && %w[month
                                                                                                  year].include?(price.dig('recurring',
                                                                                                                           'interval')) &&
             (price.dig('recurring', 'interval_count') || 1) == 1
        raise Unresolved, 'base price currency or cycle is unsupported'
      end
    end

    def valid_base_amount?(price)
      price['unit_amount'].is_a?(Integer) && price['unit_amount'] >= 0 && price['currency'] == 'jpy'
    end

    def contract_for_price(price, previous, cycle)
      metadata = price_metadata(price)
      return previous if retain_previous?(previous, price, metadata)

      terms = @catalog.definition(metadata.fetch('toybaco_plan'), metadata.fetch('toybaco_plan_version'))
      Checkout.assert_catalog_price!(price, terms, cycle)
      Entitlements.snapshot_for(terms, cycle: cycle, reference_price_id: metadata['toybaco_reference_price_id'], catalog: @catalog)
    end

    def retain_previous?(previous, price, metadata)
      return false unless previous
      return true if previous['stripe_price_id'] == price['id']

      # Bind old unversioned billing without replacing its historical rights.
      previous['legacy'] && !previous['stripe_price_id'] && metadata['toybaco_plan_version'].to_s.empty?
    end

    def purchased_addon(item, saved)
      return Entitlements.bind_addon(saved.merge('quantity' => item['quantity'], 'subscription_item_id' => item['id']), catalog: @catalog) if saved

      found = addon_for_price(item['price'])
      return unless found

      id, version = found
      Entitlements.bind_addon({
                                'id' => id, 'version' => version, 'quantity' => item['quantity'], 'source' => 'stripe',
                                'subscription_item_id' => item['id'], 'stripe_price_id' => item.dig('price', 'id')
                              }, catalog: @catalog)
    end

    def price_metadata(price)
      product = price['product'].is_a?(Hash) ? price['product'] : {}
      (product['metadata'] || {}).merge(price['metadata'] || {})
    end

    def addon_for_price(price)
      return nil unless price.is_a?(Hash)

      metadata = price_metadata(price)
      # Lookup compatibility is only for old prices without any metadata.
      return addon_for_lookup(price['lookup_key']) if metadata.empty?
      return unless metadata.key?('toybaco_addon') || metadata.key?('toybaco_addon_version')

      verified_addon_version(metadata)
    end

    def verified_addon_version(metadata)
      id, version = metadata.values_at('toybaco_addon', 'toybaco_addon_version')
      unless id.is_a?(String) && version.is_a?(String) && !id.strip.empty? && !version.strip.empty? &&
             @catalog.data.dig('addons', id, 'versions', version)
        raise Unresolved, 'addon price has no verified contract version'
      end

      [id, version]
    end

    def addon_for_lookup(lookup_key)
      return nil unless lookup_key

      matches = @catalog.data.fetch('addons').flat_map do |addon_id, addon|
        addon.fetch('versions').filter_map do |addon_version, terms|
          [addon_id, addon_version] if terms['stripe_lookup_key'] == lookup_key
        end
      end
      matches.length == 1 ? matches.first : nil
    end

    def apply_status(account, subscription, contract, outcome)
      attrs = Entitlements.attributes(account)
      status = subscription.fetch('status')
      policy = contract && contract['billing_policy']
      policy = {} unless policy.is_a?(Hash)
      updates = {
        'toybaco_subscription_status' => status,
        'toybaco_cancel_at_period_end' => subscription['cancel_at_period_end'] == true,
        'toybaco_billing_review' => outcome == 'needs_review'
      }
      state = access_state(account, attrs, updates, policy)
      account.update!(state.merge(internal_attributes: attrs.merge(updates)))
    end

    def access_state(account, attrs, updates, policy)
      status = updates['toybaco_subscription_status']
      state = {}
      if suspended_status?(policy, status)
        if account.active?
          updates['toybaco_billing_suspended'] = true
          state[:status] = 'suspended'
        end
        updates['postiz'] = (attrs['postiz'] || {}).merge('enabled' => false)
      elsif resume_billing?(policy, status, attrs, updates)
        updates['toybaco_billing_suspended'] = false
        state[:status] = 'active' if account.status.to_s == 'suspended'
      end
      state
    end

    def suspended_status?(policy, status)
      Array(policy['suspended_statuses']).include?(status) || status == 'canceled'
    end

    def resume_billing?(policy, status, attrs, updates)
      Array(policy['grace_statuses']).include?(status) && !updates['toybaco_billing_review'] && attrs['toybaco_billing_suspended'] == true
    end
  end
end
