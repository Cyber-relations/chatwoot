# frozen_string_literal: true

module Toybaco::Security::SessionRevocation
  extend ActiveSupport::Concern

  included do
    before_update :revoke_toybaco_sessions_on_credential_change
  end

  # The DTA client that completes MFA activation in this request (see ProfileMfaManagement).
  attr_accessor :toybaco_kept_client

  private

  def revoke_toybaco_sessions_on_credential_change
    return unless toybaco_credential_change?

    # Revoke all devices atomically with the credential change. A password
    # change must invalidate a copied old token, not merely its browser cookie.
    # Only the activating device survives MFA activation; it receives MFA proof next.
    kept = toybaco_kept_client if toybaco_activation_only?
    tokens_will_change!
    self.tokens = kept ? tokens.slice(kept) : {}
  end

  # A save that also changes the password, the email or the secret revokes every device, the activating one included.
  def toybaco_activation_only?
    will_save_change_to_otp_required_for_login?(to: true) &&
      !(will_save_change_to_encrypted_password? || will_save_change_to_email? || will_save_change_to_unconfirmed_email? ||
        will_save_change_to_otp_secret?)
  end

  # A secret generated before activation (the profile shows its QR code) authenticates nothing yet.
  def toybaco_credential_change?
    will_save_change_to_encrypted_password? || will_save_change_to_email? || will_save_change_to_unconfirmed_email? ||
      will_save_change_to_otp_required_for_login? || (will_save_change_to_otp_secret? && otp_required_for_login?)
  end
end
