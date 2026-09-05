# frozen_string_literal: true

require 'uri'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Checkout
    # Price 解決と戻り先 URL。円建て以外は呼び出し側で落とす。
    module Resolver
      module_function

      def price_for(terms, cycle, client:, environment: ENV)
        mode = environment.fetch('TOYBACO_STRIPE_MODE', 'live')
        raise Unavailable, 'invalid Stripe mode' unless %w[test live].include?(mode)

        reference = terms.fetch('cycles').fetch(cycle).fetch('stripe').fetch(mode)
        override = environment[reference.fetch('price_env')].to_s
        found = if override.match?(Catalog::PRICE_ID)
                  client.retrieve_price(override)
                else
                  client.find_price_by_lookup_key(reference.fetch('lookup_key'))
                end
        raise Unavailable, 'price not found' unless found.is_a?(Hash)

        found
      end

      def price(key, client:, environment: ENV)
        override = environment[Catalog::PRICE_ENV_KEYS.fetch(key)].to_s
        found = if override.match?(Catalog::PRICE_ID)
                  client.retrieve_price(override)
                else
                  client.find_price_by_lookup_key(key)
                end
        raise Unavailable, 'price not found' unless found.is_a?(Hash)

        found
      end

      def optional_price_ids(client:, cycle:)
        Catalog::OPTIONAL_LOOKUP_KEYS.fetch(cycle).filter_map do |key|
          price = client.find_price_by_lookup_key(key)
          next unless price.is_a?(Hash)
          next unless price['currency'].to_s.downcase == Catalog::CURRENCY &&
                      price['id'].to_s.match?(Catalog::PRICE_ID)

          price['id']
        rescue Error
          nil
        end
      end

      def success_url(environment)
        safe_site_url(environment['TOYBACO_CHECKOUT_SUCCESS_URL'], Catalog::DEFAULT_SUCCESS_URL)
      end

      def cancel_url(environment, plan)
        uri = URI.parse(safe_site_url(environment['TOYBACO_CHECKOUT_CANCEL_URL'], Catalog::DEFAULT_CANCEL_BASE))
        kept = URI.decode_www_form(uri.query.to_s).reject { |pair| pair.first == 'plan' }
        kept << ['plan', plan]
        uri.query = URI.encode_www_form(kept)
        uri.to_s
      end

      def safe_site_url(raw, fallback)
        value = raw.to_s.strip
        return fallback if value.empty?

        uri = URI.parse(value)
        https_site = uri.is_a?(URI::HTTPS) && uri.host == 'toybaco.jp' && uri.userinfo.nil? && uri.fragment.nil?
        https_site ? uri.to_s : fallback
      rescue URI::InvalidURIError
        fallback
      end
    end
  end
end
