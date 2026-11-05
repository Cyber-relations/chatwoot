# frozen_string_literal: true

# Middleware loads before Rails registers the reloadable lib namespaces.
module Toybaco; end
module Toybaco::Security; end

require Rails.root.join('lib/toybaco/security/attachment_transfer_boundary')

Rails.application.config.middleware.insert_before(0, Toybaco::Security::AttachmentTransferBoundary)
Rails.application.config.filter_parameters += [:upload_token]

Rails.application.routes.append do
  put '/toybaco/attachment_uploads', to: 'toybaco/attachment_uploads#update', as: :toybaco_attachment_upload
end

Rails.application.config.to_prepare do
  Attachment.prepend(Toybaco::Security::AttachmentValidation)
  Portal.prepend(Toybaco::Security::PortalLogoValidation)
  Api::V1::Accounts::PortalsController.prepend(Toybaco::Security::PortalLogoUploads)
  Onboarding::HelpCenterCreationService.prepend(Toybaco::Security::PortalLogoImport) if defined?(Onboarding::HelpCenterCreationService)
  Call.prepend(Toybaco::Security::CallRecordingValidation) if defined?(Call)
  DataImport.prepend(Toybaco::Security::ImportFileValidation)
  Captain::Document.prepend(Toybaco::Security::PdfFileValidation) if defined?(Captain::Document)
  Captain::Document.prepend(Toybaco::Security::MarkdownFileValidation) if defined?(Captain::Document)
  Message.include(Toybaco::Security::AttachmentValidation::MessageContext)
  Messages::MessageBuilder.prepend(Toybaco::Security::AttachmentValidation::MessageBuilder)
  Sms::IncomingMessageService.prepend(Toybaco::Security::AttachmentSms)
  ActiveStorage::DirectUploadsController.prepend(Toybaco::Security::AttachmentUploads::DisableStockDirectUpload)
  Api::V1::Accounts::UploadController.prepend(Toybaco::Security::AttachmentUploads::AccountUpload)
  Api::V1::Accounts::Conversations::DirectUploadsController.prepend(Toybaco::Security::AttachmentUploads::DirectUpload)
  Api::V1::Widget::DirectUploadsController.prepend(Toybaco::Security::AttachmentUploads::DirectUpload)
  MailPresenter.prepend(Toybaco::Security::AttachmentMail::Presenter)
  MailboxHelper.prepend(Toybaco::Security::AttachmentMail::Mailbox)
end
