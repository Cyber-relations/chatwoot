# frozen_string_literal: true

require 'net/http'

# Only Shopify's authenticated response for the currently stored token authorizes
# cleanup. Never follow redirects or send credentials to a body/header URL.
class Toybaco::Security::ShopifyInstallationStatus
  class Unavailable < StandardError; end

  def initialize(hook)
    @shop = Shopify::ShopDomain.normalize(hook.reference_id)
    @access_token = hook.access_token
  end

  def removed?
    raise Unavailable, 'Shopify installation verification unavailable' unless verifiable?

    code = response_code
    # A 403 can reflect access policy, scopes or plan limits for an active install.
    return true if code == 401
    return false if (200..299).cover?(code)

    raise Unavailable, 'Shopify installation verification unavailable'
  end

  private

  def verifiable?
    Shopify::ShopDomain.valid?(@shop) && @shop.end_with?('.myshopify.com') && @access_token.present?
  end

  def response_code
    request = Net::HTTP::Get.new('/admin/oauth/access_scopes.json')
    request['X-Shopify-Access-Token'] = @access_token
    http_client.start { |http| http.request(request).code.to_i }
  rescue IOError, SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError, Net::ProtocolError, Net::HTTPBadResponse
    raise Unavailable, 'Shopify installation verification unavailable'
  end

  def http_client
    Net::HTTP.new(@shop, 443, nil).tap do |http|
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 5
      http.write_timeout = 5
      http.max_retries = 0
    end
  end
end
