# frozen_string_literal: true

require_relative 'entitlements'
require_relative 'checkout'
require_relative 'subscription_sync_status'
require_relative 'growth/paid_period'
require_relative 'growth/paid_transition'
require_relative 'growth/scheduled_downgrade_grace'
require_relative 'growth/inbox_upgrade_continuation'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  # Webhooks carry a subscription ID, never authoritative plan or access state.
  # Read the latest Stripe object under the account lock so retries/old events
  # cannot overwrite a newer contract with their stale payload.
  class SubscriptionSync
    include SubscriptionSyncStatus

    class Unresolved < StandardError; end

    # free_return: only the caller that runs the period-end Free return after this Sync
    # opts in; every other caller keeps the existing suspension of an ended subscription.
    def initialize(client:, catalog: PlanCatalog.default, environment: ENV, free_return: false)
      @client = client
      @catalog = catalog
      @environment = environment
      @free_return = free_return
    end

    # A guard sees the fresh subscription before any write and decides how a renewal
    # period waits: :wait writes nothing, :status_only writes two status fields, nil runs
    # the full Sync. Both waiting forms return 'renewal_pending'.
    def call(account, subscription_id:, guard: nil)
      outcome = nil
      account.with_lock do
        attrs = Entitlements.attributes(account)
        raise Unresolved, 'subscription does not belong to account' unless attrs['toybaco_subscription_id'] == subscription_id

        subscription = retrieve_subscription(subscription_id)
        outcome = apply_decision(account, subscription, guard&.call(account, subscription))
        yield subscription, outcome if block_given?
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

    def apply_decision(account, subscription, decision)
      case decision
      when nil then apply_fresh(account, subscription)
      when :status_only then apply_status_only(account, subscription)
      when :wait then 'renewal_pending'
      else raise ArgumentError, 'unknown subscription guard decision'
      end
    end

    def apply_fresh(account, subscription)
      contract, outcome = apply_contract(account, subscription, previous_contract(account))
      apply_status(account, subscription, contract, outcome)
      Growth::PaidPeriod.new(account).observe!(subscription) if outcome == 'applied'
      outcome
    end

    def apply_contract(account, subscription, previous)
      contract = resolve(subscription, previous: previous)
      return [previous, 'payment_pending'] unless Growth::PaidTransition.allowed?(subscription, contract, previous)

      Growth::ScheduledDowngradeGrace.new(account).paid_ready?(subscription, contract)
      Growth::InboxUpgradeContinuation.new(account, subscription, previous, contract).call do
        Entitlements.apply!(account, contract, subscription_id: subscription.fetch('id'), catalog: @catalog)
      end
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
  end
end
