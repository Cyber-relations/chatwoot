# frozen_string_literal: true

# The issuer is copied into authenticator apps when their QR code is scanned.
# Changing this label does not rotate an existing user's secret or backup codes.
module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module MfaProvisioningBrand
    def two_factor_provisioning_uri
      return nil if user.otp_secret.blank?

      user.otp_provisioning_uri(user.email, issuer: 'トイバコ')
    end
  end
end

Rails.application.config.to_prepare do
  Mfa::ManagementService.prepend(Toybaco::MfaProvisioningBrand) unless Mfa::ManagementService < Toybaco::MfaProvisioningBrand
end
