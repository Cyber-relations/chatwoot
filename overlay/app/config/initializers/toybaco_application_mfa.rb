# frozen_string_literal: true

Rails.application.config.to_prepare do
  User.prepend(Toybaco::Security::ApplicationMfaSession::TokenValidation)
  Toybaco::Oidc::SessionReader.singleton_class.prepend(Toybaco::Security::ApplicationMfaSession::ReaderValidation)
  Mfa::AuthenticationService.prepend(Toybaco::Security::ApplicationMfaSession::SingleUseVerification)
  DeviseOverrides::SessionsController.prepend(Toybaco::Security::ApplicationMfaLogin)
  Api::V1::Profile::MfaController.prepend(Toybaco::Security::ProfileMfaManagement)
end

# One line per boot makes a mistyped TOYBACO_APPLICATION_MFA_MAX_AGE_HOURS visible; invalid values never raise.
Rails.application.config.after_initialize do
  Rails.logger.info("toybaco_application_mfa_max_age_hours=#{Toybaco::Security::ApplicationMfaSession.max_age.in_hours.to_i}")
end

Rails.application.routes.append do
  get '/toybaco/mfa-enrollment', to: 'toybaco/mfa_enrollment#show'
  post '/toybaco/mfa-enrollment', to: 'toybaco/mfa_enrollment#create'
  post '/toybaco/mfa-enrollment/verify', to: 'toybaco/mfa_enrollment#verify'
  post '/toybaco/mfa-enrollment/cancel', to: 'toybaco/mfa_enrollment#cancel'
end
