# frozen_string_literal: true

require_relative '../../lib/toybaco/growth/inbox_retention_boundaries'
require_relative '../../lib/toybaco/growth/inbox_retention_ingress'
require_relative '../../lib/toybaco/growth/inbox_dispatch_jobs'
require_relative '../../lib/toybaco/growth/inbox_notification_content'
require_relative '../../lib/toybaco/growth/inbox_contract_boundary'
require_relative '../../lib/toybaco/growth/posting_membership_boundary'

Rails.application.config.to_prepare do
  contract_updates = Toybaco::Growth::InboxContractBoundary::AccountUpdates
  Account.include(contract_updates) unless contract_updates >= Account
  membership = Toybaco::Growth::PostingMembershipBoundary::MembershipWrites
  AccountUser.include(membership) unless membership >= AccountUser
  user = Toybaco::Growth::PostingMembershipBoundary::UserWrites
  User.include(user) unless user >= User
end

Rails.application.config.to_prepare do
  boundaries = Toybaco::Growth::InboxRetentionBoundaries
  ApplicationController.include(boundaries::HttpErrors) unless ApplicationController < boundaries::HttpErrors
  PublicController.include(boundaries::HttpErrors) unless PublicController < boundaries::HttpErrors
  SendReplyJob.prepend(boundaries::SendJob) unless SendReplyJob < boundaries::SendJob
  Base::SendOnChannelService.prepend(boundaries::SendService) unless Base::SendOnChannelService < boundaries::SendService
  Email::SendOnEmailService.prepend(boundaries::SendService) unless Email::SendOnEmailService < boundaries::SendService
  Toybaco::Connections::GmailSend.prepend(boundaries::SendService) unless Toybaco::Connections::GmailSend < boundaries::SendService
  Toybaco::Connections::MicrosoftSend.prepend(boundaries::SendService) unless Toybaco::Connections::MicrosoftSend < boundaries::SendService
  Messages::SendEmailNotificationService.prepend(boundaries::SendService) unless Messages::SendEmailNotificationService < boundaries::SendService
  ConversationReplyMailer.include(boundaries::MailDelivery) unless ConversationReplyMailer < boundaries::MailDelivery
  Message.include(boundaries::MessageCreation) unless Message < boundaries::MessageCreation
  Messages::MessageBuilder.prepend(boundaries::Builder) unless Messages::MessageBuilder < boundaries::Builder
  unless Api::V1::Accounts::Conversations::MessagesController < boundaries::Retry
    Api::V1::Accounts::Conversations::MessagesController.prepend(boundaries::Retry)
  end
  Inboxes::FetchImapEmailsJob.prepend(boundaries::FetchJob) unless Inboxes::FetchImapEmailsJob < boundaries::FetchJob
  Toybaco::GmailFetchJob.prepend(boundaries::OAuthFetchJob) unless Toybaco::GmailFetchJob < boundaries::OAuthFetchJob
  Toybaco::MicrosoftFetchJob.prepend(boundaries::OAuthFetchJob) unless Toybaco::MicrosoftFetchJob < boundaries::OAuthFetchJob
  Imap::BaseFetchEmailService.prepend(boundaries::ChannelService) unless Imap::BaseFetchEmailService < boundaries::ChannelService
  Imap::ImapMailbox.prepend(boundaries::ImapMailbox) unless Imap::ImapMailbox < boundaries::ImapMailbox
  Toybaco::Connections::GmailIngest.prepend(boundaries::OAuthIngest) unless Toybaco::Connections::GmailIngest < boundaries::OAuthIngest
  Toybaco::Connections::MicrosoftIngest.prepend(boundaries::OAuthIngest) unless Toybaco::Connections::MicrosoftIngest < boundaries::OAuthIngest
  Line::IncomingMessageService.prepend(boundaries::InboxService) unless Line::IncomingMessageService < boundaries::InboxService
  Messages::Facebook::MessageBuilder.prepend(boundaries::InboxService) unless Messages::Facebook::MessageBuilder < boundaries::InboxService
  Instagram::BaseMessageText.prepend(boundaries::ChannelService) unless Instagram::BaseMessageText < boundaries::ChannelService
  unless Mailbox::ConversationFinderStrategies::NewConversationStrategy < boundaries::NewMailConversation
    Mailbox::ConversationFinderStrategies::NewConversationStrategy.prepend(boundaries::NewMailConversation)
  end
  ReplyMailbox.include(boundaries::MailboxProcessing) unless ReplyMailbox < boundaries::MailboxProcessing
  ReplyMailbox.prepend(boundaries::ReplyMailbox) unless ReplyMailbox < boundaries::ReplyMailbox
end

Rails.application.config.to_prepare do
  targets = Toybaco::Growth::InboxRetentionBoundaries::MailTargets
  ConversationReplyMailer.prepend(targets) unless targets >= ConversationReplyMailer
  content = Toybaco::Growth::InboxNotificationContent
  ConversationReplyMailer.prepend(content) unless content >= ConversationReplyMailer
  scheduling = Toybaco::Growth::InboxNotification::Scheduling
  Messages::SendEmailNotificationService.prepend(scheduling) unless scheduling >= Messages::SendEmailNotificationService
  jobs = Toybaco::Growth::InboxDispatchJobs
  [[SendReplyJob, jobs::Reply], [ConversationReplyEmailJob, jobs::Notification], [ActionMailer::MailDeliveryJob, jobs::Mail]].each do |klass, adapter|
    klass.include(jobs::Snapshot) unless klass < jobs::Snapshot
    klass.prepend(adapter) unless klass < adapter
  end
end

Rails.application.config.to_prepare do
  boundaries = Toybaco::Growth::InboxRetentionBoundaries
  ingress = Toybaco::Growth::InboxRetentionIngress
  ContactInboxWithContactBuilder.prepend(boundaries::InboxService) unless ContactInboxWithContactBuilder < boundaries::InboxService
  Conversation.include(ingress::ConversationCreation) unless Conversation < ingress::ConversationCreation
  Sms::IncomingMessageService.prepend(boundaries::InboxService) unless Sms::IncomingMessageService < boundaries::InboxService
  Telegram::IncomingMessageService.prepend(boundaries::InboxService) unless Telegram::IncomingMessageService < boundaries::InboxService
  Twilio::IncomingMessageService.prepend(ingress::Twilio) unless Twilio::IncomingMessageService < ingress::Twilio
  Whatsapp::IncomingMessageBaseService.prepend(ingress::Whatsapp) unless Whatsapp::IncomingMessageBaseService < ingress::Whatsapp
  Tiktok::MessageService.prepend(boundaries::ChannelService) unless Tiktok::MessageService < boundaries::ChannelService
  [Public::Api::V1::Inboxes::ContactsController, Public::Api::V1::Inboxes::ConversationsController,
   Public::Api::V1::Inboxes::MessagesController].each do |controller|
    controller.prepend(ingress::PublicCreate) unless controller < ingress::PublicCreate
  end
  widget_messages = Api::V1::Widget::MessagesController
  widget_messages.include(ingress::WidgetMessages) unless widget_messages < ingress::WidgetMessages
  widget_conversations = Api::V1::Widget::ConversationsController
  widget_conversations.include(ingress::WidgetConversations) unless widget_conversations < ingress::WidgetConversations
end
