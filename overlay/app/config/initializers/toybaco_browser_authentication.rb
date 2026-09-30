# frozen_string_literal: true

require_relative '../../lib/toybaco/security/browser_cookie_expiry'

Rails.application.config.middleware.insert_before Warden::Manager, Toybaco::Security::BrowserCookieExpiry

Rails.application.config.to_prepare do
  User.include(Toybaco::Security::CredentialRevocation)
  [ApplicationController, Api::V1::Accounts::Conversations::DirectUploadsController].each do |controller|
    controller.prepend(Toybaco::Security::BrowserAuthentication)
    controller.prepend_before_action :prepare_toybaco_browser_authentication
  end
end

Rails.application.routes.append do
  get '/toybaco/browser-session', to: 'toybaco/browser_session#show'
end
