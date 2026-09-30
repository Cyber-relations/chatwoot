# frozen_string_literal: true

module Toybaco::Security::SessionRevocation
  extend ActiveSupport::Concern

  included do
    before_update :revoke_toybaco_sessions_on_credential_change
  end

  private

  def revoke_toybaco_sessions_on_credential_change
    return unless will_save_change_to_encrypted_password? || will_save_change_to_email? || will_save_change_to_unconfirmed_email?

    # Revoke all devices atomically with the credential change. A password
    # change must invalidate a copied old token, not merely its browser cookie.
    self.tokens = {}
  end
end
