# frozen_string_literal: true

Rails.application.config.to_prepare do
  User.prepend(Toybaco::Security::ApplicationMfaSession::TokenValidation)
  Toybaco::Oidc::SessionReader.singleton_class.prepend(Toybaco::Security::ApplicationMfaSession::ReaderValidation)
  Mfa::AuthenticationService.prepend(Toybaco::Security::ApplicationMfaSession::SingleUseVerification)
  DeviseOverrides::SessionsController.prepend(Toybaco::Security::ApplicationMfaLogin)
end

Rails.application.routes.append do
  get '/toybaco/mfa-enrollment', to: 'toybaco/mfa_enrollment#show'
  post '/toybaco/mfa-enrollment', to: 'toybaco/mfa_enrollment#create'
  post '/toybaco/mfa-enrollment/verify', to: 'toybaco/mfa_enrollment#verify'
  post '/toybaco/mfa-enrollment/cancel', to: 'toybaco/mfa_enrollment#cancel'
end
