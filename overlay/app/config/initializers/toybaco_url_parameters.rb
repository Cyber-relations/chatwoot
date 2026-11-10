# frozen_string_literal: true

# CASA 5.1.1: upstream hand-built URLs that take request values without encoding them. Each value is limited to its form and
# encoded: the SAML start (RelayState and the assertion consumer service URL), the Slack fallback image and the Facebook
# page image. The Shopify start URL is fixed with its connection state (Toybaco::Connections::ProviderOauthState).

require_relative '../../lib/toybaco/security/saml_request_params'

# OmniAuth strategies are gem classes and are not reloaded: prepend once, at load.
OmniAuth::Strategies::SAML.prepend(Toybaco::Security::SamlRequestParams::Setup)

Rails.application.config.to_prepare do
  Api::V1::AuthController.prepend(Toybaco::Security::SamlRequestParams::Login)
  SlackUploadsController.prepend(Toybaco::Security::SlackUploadAvatar)
  Api::V1::Accounts::CallbacksController.prepend(Toybaco::Security::FacebookPageAvatar)
end
