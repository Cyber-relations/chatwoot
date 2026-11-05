# frozen_string_literal: true

module Toybaco::Security::PortalLogoImport
  private

  def attach_brand_logo(portal)
    super
    return if portal.errors[:logo].empty?

    # ActiveStorage#attach returns nil on validation failure; the upstream
    # exception logger cannot see that outcome. Keep onboarding going and record
    # the omission without logging the imported URL, filename or response body.
    Rails.logger.warn("TOYBACO_PORTAL_LOGO_NOT_IMPORTED account=#{@account.id} portal=#{portal.id} reason=validation_rejected")
  end
end
