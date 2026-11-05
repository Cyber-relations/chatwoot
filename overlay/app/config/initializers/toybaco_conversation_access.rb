# frozen_string_literal: true

Rails.application.config.to_prepare do
  Api::V1::Accounts::Captain::TasksController.prepend(Toybaco::Security::ConversationAccess::CaptainTasks)
  Api::V1::Accounts::Integrations::LinearController.prepend(Toybaco::Security::ConversationAccess::Linear)
  Api::V1::Accounts::Conversations::DirectUploadsController.prepend(Toybaco::Security::ConversationAccess::DirectUploads)
end
