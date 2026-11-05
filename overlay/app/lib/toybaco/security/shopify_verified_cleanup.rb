# frozen_string_literal: true

class Toybaco::Security::ShopifyVerifiedCleanup
  def initialize(hook)
    @hook = hook
  end

  def perform
    # Match the callback and native uninstall lock order. Reload and verify under
    # these locks so a reconnect cannot replace the token between check and delete.
    @hook.account.with_lock do
      hook = @hook.account.hooks.lock.find_by(id: @hook.id, app_id: 'shopify')
      next unless hook && Toybaco::Security::ShopifyInstallationStatus.new(hook).removed?

      # Every topic has the same outcome. No unsigned topic or time can choose
      # a more destructive operation. Preserve native Enterprise expiry sync.
      Shopify::UninstallationService.new(hook: hook, delete_hook: true).perform
    end
  end
end
