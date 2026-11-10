# frozen_string_literal: true

Rails.application.config.to_prepare do
  DeviseTokenAuth::RegistrationsController.prepend(Toybaco::Security::RegistrationMutations)
  Api::V1::ProfilesController.prepend(Toybaco::Security::ProfileEmailChange)
  AccessTokenAuthHelper.prepend(Toybaco::Security::PersonalApiAuthentication)
  PlatformController.prepend(Toybaco::Security::PlatformApiGuard)
  # The upstream reports demo seeder creates agents with a fixed password; it never runs in production.
  Seeders::Reports::ReportDataSeeder.prepend(Toybaco::Security::ReportsSeedGuard)
  # Devise Confirmable notifies the old address when reconfirmation is requested.
  User.send_email_changed_notification = true
end
