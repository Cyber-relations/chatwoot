# frozen_string_literal: true

require_relative '../../lib/toybaco/connections/google_authorization'
require_relative '../../lib/toybaco/connections/gmail_send'
require_relative '../../lib/toybaco/connections/gmail_schedule'
require_relative '../../lib/toybaco/connections/gmail_cleanup'
require_relative '../../lib/toybaco/connections/gmail_message_boundary'

Rails.application.config.filter_parameters += %i[code state code_verifier credentials client_secret refresh_token access_token]

Rails.application.routes.append do
  get '/toybaco/connections/gmail/callback', to: 'toybaco/gmail_callback#show'
end

Rails.application.config.to_prepare do
  Api::V1::Accounts::Google::AuthorizationsController.prepend(Toybaco::Connections::GoogleAuthorization)
  Email::SendOnEmailService.prepend(Toybaco::Connections::GmailSendRouting)
  ConversationReplyMailer.prepend(Toybaco::Connections::GmailMailer)
  Inboxes::FetchImapEmailInboxesJob.prepend(Toybaco::Connections::GmailSchedule)
  Channel::Email.include(Toybaco::Connections::GmailCleanup)
  Messages::MessageBuilder.prepend(Toybaco::Connections::GmailMessageBoundary::Builder)
  Api::V1::Accounts::Conversations::MessagesController.prepend(Toybaco::Connections::GmailMessageBoundary::Retry)
end
