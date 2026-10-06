# frozen_string_literal: true

# Completing MFA from the profile revokes every other device and keeps the one
# that proved the code, now with MFA proof, so the user stays signed in.
module Toybaco::Security::ProfileMfaManagement
  # Activation and the proof commit together under the user's row lock, so the kept device is never
  # enabled without proof. The response is rendered after this method returns, outside the transaction.
  def verify
    current_user.with_lock do
      was_enabled = current_user.mfa_enabled?
      current_user.toybaco_kept_client = toybaco_current_client
      super
      client = current_user.toybaco_kept_client
      # Proof only for an activation made by this request, never for a user who had MFA already.
      if client && !was_enabled && current_user.mfa_enabled? && response.status == 200
        Toybaco::Security::ApplicationMfaSession.attach_proof!(current_user, client)
      end
    end
  ensure
    current_user&.toybaco_kept_client = nil
  end

  private

  # Only a DTA device record identifies the device; API access tokens keep nothing.
  def toybaco_current_client
    client = @token&.client
    client if client.present? && current_user.tokens.key?(client)
  end
end
