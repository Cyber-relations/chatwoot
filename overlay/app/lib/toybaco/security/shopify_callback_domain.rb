# frozen_string_literal: true

module Toybaco::Security::ShopifyCallbackDomain
  private

  def oauth_client
    shop = Shopify::ShopDomain.normalize(params[:shop])
    # ShopDomain also permits .io; this callback intentionally accepts only .com.
    raise ArgumentError, 'Invalid Shopify shop domain' unless Shopify::ShopDomain.valid?(shop) && shop.end_with?('.myshopify.com')

    params[:shop] = shop
    super
  end
end
