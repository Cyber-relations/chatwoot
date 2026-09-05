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
        "lookup_keys[]=#{CGI.escape(lookup_key)}&currency=#{Catalog::CURRENCY}&active=true&limit=1&expand[]=data.product"
      end

      def find_price_by_lookup_key(lookup_key)
        request(:get, "/v1/prices?#{self.class.price_search_query(lookup_key)}").fetch('data', []).first
      end

      def retrieve_price(price_id)
        raise Unavailable, 'invalid price id' unless price_id.to_s.match?(Catalog::PRICE_ID)

        request(:get, "/v1/prices/#{price_id}?expand[]=product")
      end

      def retrieve_subscription(subscription_id)
        raise Unavailable, 'invalid subscription id' unless subscription_id.to_s.match?(/\Asub_[A-Za-z0-9]+\z/)

        query = URI.encode_www_form([
                                      ['expand[]', 'items.data.price.product'], ['expand[]', 'latest_invoice']
                                    ])
        request(:get, "/v1/subscriptions/#{subscription_id}?#{query}")
      end

      def create_customer(params)
        request(:post, '/v1/customers', params)
      end

      def create_checkout_session(params)
        request(:post, '/v1/checkout/sessions', params)
      end

      def preview_plan_change(params)
        request(:post, '/v1/invoices/create_preview', flatten_form(params))
      end

      def update_subscription(id, params, idempotency_key:)
        raise Unavailable, 'invalid subscription id' unless id.to_s.match?(/\Asub_[A-Za-z0-9]+\z/)

        request(:post, "/v1/subscriptions/#{id}", flatten_form(params), idempotency_key: idempotency_key)
      end

      def create_subscription_schedule(subscription_id, idempotency_key:)
        request(:post, '/v1/subscription_schedules', { 'from_subscription' => subscription_id }, idempotency_key: idempotency_key)
      end

      def retrieve_subscription_schedule(id)
        request(:get, schedule_path(id))
      end

      def update_subscription_schedule(id, params, idempotency_key:)
        request(:post, schedule_path(id), flatten_form(params), idempotency_key: idempotency_key)
      end

      def release_subscription_schedule(id, idempotency_key:)
        request(:post, "#{schedule_path(id)}/release", { 'preserve_cancel_date' => 'true' }, idempotency_key: idempotency_key)
      end

      private

      def schedule_path(id)
        raise Unavailable, 'invalid schedule id' unless id.to_s.match?(/\Asub_sched_[A-Za-z0-9]+\z/)

        "/v1/subscription_schedules/#{id}"
      end

      def form_key(prefix, key)
        prefix ? "#{prefix}[#{key}]" : key.to_s
      end

      def flatten_form(value, prefix = nil, result = {})
        case value
        when Hash
          value.each { |key, child| flatten_form(child, form_key(prefix, key), result) }
        when Array
          value.each_with_index { |child, index| flatten_form(child, "#{prefix}[#{index}]", result) }
          result[prefix] = '' if value.empty?
        else
          result[prefix] = value.to_s unless value.nil?
        end
        result
      end

      def request(method, path, params = nil, idempotency_key: nil)
        uri = URI("https://api.stripe.com#{path}")
        req = method == :get ? Net::HTTP::Get.new(uri) : Net::HTTP::Post.new(uri)
        req.basic_auth(@api_key, '')
        req['Idempotency-Key'] = idempotency_key if idempotency_key
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
