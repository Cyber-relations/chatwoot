# frozen_string_literal: true

require_relative 'checkout/catalog'
require_relative 'checkout/line_item'
require_relative 'checkout/session_form'
require_relative 'checkout/client'
require_relative 'checkout/resolver'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  # LP で選んだプランを Stripe Checkout Session に載せる。
  # locale/通貨/請求国は日本向けに固定し、円建て以外の Price は作らない。
  module Checkout
    class Error < StandardError; end
    class InvalidPlan < Error; end
    class NonJpyPrice < Error; end
    class Unavailable < Error; end

    module_function

    def start!(plan:, cycle: 'month', version: nil, client: nil, environment: ENV)
      plan, cycle = normalize_selection(plan, cycle)
      terms = Catalog.sale(plan, cycle, version: version)
      urls = Resolver.return_urls(environment, plan: plan, cycle: cycle, version: terms.fetch('plan_version'))
      http = client || Client.new(environment['TOYBACO_STRIPE_KEY'])
      price = Resolver.price_for(terms, cycle, client: http, environment: environment)
      assert_catalog_price!(price, terms, cycle, environment)
      customer = http.create_customer(customer_params(plan: plan, cycle: cycle))
      http.create_checkout_session(
        session_params(
          plan: plan, cycle: cycle, version: terms.fetch('plan_version'), price: price, customer_id: customer.fetch('id'),
          **urls,
          optional_price_ids: Resolver.optional_price_ids(client: http, cycle: cycle)
        )
      )
    end

    def assert_catalog_price!(price, terms, cycle, environment = nil)
      assert_jpy!(price, cycle)
      expected = terms.fetch('cycles').fetch(cycle)
      raise Unavailable, 'price does not match advertised terms' unless price['unit_amount'] == expected.fetch('amount')

      if environment && price.key?('livemode')
        mode = environment.fetch('TOYBACO_STRIPE_MODE', 'live')
        raise Unavailable, 'invalid Stripe mode' unless %w[test live].include?(mode)
        raise Unavailable, 'Stripe mode mismatch' unless price['livemode'] == (mode == 'live')
      end
      true
    end

    def normalize_selection(plan, cycle)
      selected_plan = plan.to_s.strip
      selected_cycle = cycle.to_s.strip
      selected_cycle = 'month' if selected_cycle.empty?
      raise InvalidPlan unless Catalog::PLANS.include?(selected_plan) && Catalog::CYCLES.include?(selected_cycle)

      [selected_plan, selected_cycle]
    end

    def lookup_key(plan, cycle)
      selected_plan, selected_cycle = normalize_selection(plan, cycle)
      Catalog::LOOKUP_KEYS.fetch(selected_plan).fetch(selected_cycle)
    end

    def assert_jpy!(price, cycle = nil)
      raise NonJpyPrice, 'price is not JPY' unless jpy_subscription_price?(price, cycle)
    end

    def jpy_subscription_price?(price, cycle)
      return false unless price.is_a?(Hash)
      return false unless price['currency'].to_s.downcase == Catalog::CURRENCY
      return false unless price['id'].to_s.match?(Catalog::PRICE_ID)

      amount = price['unit_amount']
      return false unless amount.is_a?(Integer) && amount.positive?
      return true if cycle.nil?

      price.dig('recurring', 'interval').to_s == cycle
    end

    def customer_params(plan:, cycle:)
      selected_plan, selected_cycle = normalize_selection(plan, cycle)
      {
        'address[country]' => Catalog::COUNTRY,
        'preferred_locales[]' => Catalog::LOCALE,
        'metadata[toybaco_plan]' => selected_plan,
        'metadata[toybaco_plan_version]' => Catalog.sale(selected_plan, selected_cycle).fetch('plan_version'),
        'metadata[toybaco_cycle]' => selected_cycle
      }
    end

    def session_params(**input)
      plan, cycle = normalize_selection(input.fetch(:plan), input.fetch(:cycle))
      price = input.fetch(:price)
      terms = Catalog.sale(plan, cycle, version: input[:version])
      assert_catalog_price!(price, terms, cycle)
      customer_id = input.fetch(:customer_id)
      raise InvalidPlan unless customer_id.to_s.match?(Catalog::CUSTOMER_ID)

      SessionForm.build(input.merge(plan: plan, cycle: cycle, version: terms.fetch('plan_version'), customer_id: customer_id))
    end
  end
end
