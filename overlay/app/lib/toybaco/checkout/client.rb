# frozen_string_literal: true

require 'cgi'
require 'json'
require 'net/http'
require 'openssl'
require 'uri'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Checkout
    # Stripe への form POST。キーはログにも例外にも出さない。
    class Client
      def initialize(api_key)
        @api_key = api_key.to_s
        raise Unavailable, 'stripe key missing' if @api_key.empty?
      end

      def self.price_search_query(lookup_key)
        "lookup_keys[]=#{CGI.escape(lookup_key)}&currency=#{Catalog::CURRENCY}&active=true&limit=1"
      end

      def find_price_by_lookup_key(lookup_key)
        request(:get, "/v1/prices?#{self.class.price_search_query(lookup_key)}").fetch('data', []).first
      end

      def retrieve_price(price_id)
        raise Unavailable, 'invalid price id' unless price_id.to_s.match?(Catalog::PRICE_ID)

        request(:get, "/v1/prices/#{price_id}")
      end

      def create_customer(params)
        request(:post, '/v1/customers', params)
      end

      def create_checkout_session(params)
        request(:post, '/v1/checkout/sessions', params)
      end

      private

      def request(method, path, params = nil)
        uri = URI("https://api.stripe.com#{path}")
        req = method == :get ? Net::HTTP::Get.new(uri) : Net::HTTP::Post.new(uri)
        req.basic_auth(@api_key, '')
        req.set_form_data(params) if params
        res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 15) do |http|
          http.request(req)
        end
        raise Error, "stripe #{res.code}" unless res.is_a?(Net::HTTPSuccess)

        JSON.parse(res.body)
      rescue JSON::ParserError, SocketError, Timeout::Error, Errno::ECONNREFUSED, OpenSSL::SSL::SSLError
        raise Error, 'stripe request failed'
      end
    end
  end
end
