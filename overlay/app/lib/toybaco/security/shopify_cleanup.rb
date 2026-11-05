# frozen_string_literal: true

module Toybaco::Security::ShopifyCleanup
  def events
    shop = cleanup_shop
    shopify_hooks(shop).find_each { |hook| Toybaco::Security::ShopifyVerifiedCleanup.new(hook).perform } if shop
    head :ok
  rescue Toybaco::Security::ShopifyInstallationStatus::Unavailable
    Rails.logger.warn('Shopify installation verification unavailable')
    head :service_unavailable
  end

  private

  def cleanup_shop
    domains = [params[:shop_domain], params[:myshopify_domain]].compact
    return if domains.empty?

    raise ActionController::BadRequest, 'Invalid Shopify shop' unless domains.all?(String)

    domains = domains.map { |domain| Shopify::ShopDomain.normalize(domain) }.uniq
    raise ActionController::BadRequest, 'Invalid Shopify shop' unless domains.one? && Shopify::ShopDomain.valid?(domains.first)

    domains.first
  end

  def ensure_shopify_enabled
    # Cleanup remains available for existing hooks even if new installs are off.
    # Always reach HMAC verification, independent of the unsigned topic header.
  end

  def mandatory_cleanup_event?
    false
  end
end
