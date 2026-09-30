# frozen_string_literal: true

module AuthHelper
  def send_auth_headers(user)
    data = issue_toybaco_auth_token(user)
    response.headers[DeviseTokenAuth.headers_names[:'access-token']] = data['access-token']
    response.headers[DeviseTokenAuth.headers_names[:'token-type']]   = 'Bearer'
    response.headers[DeviseTokenAuth.headers_names[:client]]       = data['client']
    response.headers[DeviseTokenAuth.headers_names[:expiry]]       = data['expiry']
    response.headers[DeviseTokenAuth.headers_names[:uid]]          = data['uid']
    publish_toybaco_direct_auth_headers(user, data) if respond_to?(:publish_toybaco_direct_auth_headers)
  end

  private

  def issue_toybaco_auth_token(user)
    user.with_lock do
      proof = inherited_toybaco_mfa_proof(user)
      data = user.create_new_auth_token
      if proof.present?
        user.tokens.fetch(data.fetch('client')).merge!(proof)
        user.save!
      end
      data
    end
  end

  def inherited_toybaco_mfa_proof(user)
    return unless current_user&.id == user.id && user.mfa_enabled?

    client = @token&.client
    return unless Toybaco::Security::ApplicationMfaSession.valid?(user, client)

    user.tokens.fetch(client).slice('toybaco_mfa_at', 'toybaco_mfa_proof')
  end
end
