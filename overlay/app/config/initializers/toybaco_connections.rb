# frozen_string_literal: true

require_relative '../../lib/toybaco/connections/google_authorization'
require_relative '../../lib/toybaco/connections/gmail_send'
require_relative '../../lib/toybaco/connections/gmail_schedule'
require_relative '../../lib/toybaco/connections/gmail_cleanup'
require_relative '../../lib/toybaco/connections/gmail_message_boundary'
require_relative '../../lib/toybaco/connections/microsoft_authorization'
require_relative '../../lib/toybaco/connections/microsoft_send'
require_relative '../../lib/toybaco/connections/microsoft_schedule'
require_relative '../../lib/toybaco/connections/microsoft_message_boundary'

Rails.application.config.filter_parameters += %i[code state code_verifier credentials client_secret refresh_token access_token]

Rails.application.routes.append do
  get '/toybaco/connections/gmail/callback', to: 'toybaco/gmail_callback#show'
  get '/toybaco/connections/microsoft/callback', to: 'toybaco/microsoft_callback#show'
end

Rails.application.config.to_prepare do
  Api::V1::Accounts::Google::AuthorizationsController.prepend(Toybaco::Connections::GoogleAuthorization)
  Api::V1::Accounts::Microsoft::AuthorizationsController.prepend(Toybaco::Connections::MicrosoftAuthorization)
  Email::SendOnEmailService.prepend(Toybaco::Connections::GmailSendRouting)
  Email::SendOnEmailService.prepend(Toybaco::Connections::MicrosoftSendRouting)
  ConversationReplyMailer.prepend(Toybaco::Connections::GmailMailer)
  ConversationReplyMailer.prepend(Toybaco::Connections::MicrosoftMailer)
  Inboxes::FetchImapEmailInboxesJob.prepend(Toybaco::Connections::GmailSchedule)
  Inboxes::FetchImapEmailInboxesJob.prepend(Toybaco::Connections::MicrosoftSchedule)
  Channel::Email.include(Toybaco::Connections::GmailCleanup)
  Messages::MessageBuilder.prepend(Toybaco::Connections::GmailMessageBoundary::Builder)
  Messages::MessageBuilder.prepend(Toybaco::Connections::MicrosoftMessageBoundary::Builder)
  Api::V1::Accounts::Conversations::MessagesController.prepend(Toybaco::Connections::GmailMessageBoundary::Retry)
  Api::V1::Accounts::Conversations::MessagesController.prepend(Toybaco::Connections::MicrosoftMessageBoundary::Retry)
end
