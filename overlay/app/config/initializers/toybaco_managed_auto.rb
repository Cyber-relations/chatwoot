# frozen_string_literal: true

Rails.application.routes.append do
  get '/toybaco/growth/automatic-replies', to: 'toybaco/managed_auto#show'
  post '/toybaco/growth/automatic-replies', to: 'toybaco/managed_auto#create'
  put '/toybaco/growth/automatic-replies', to: 'toybaco/managed_auto#update'
end

Rails.application.config.to_prepare do
  require_relative '../../lib/toybaco/growth/managed_auto_boundaries'
  require_relative '../../lib/toybaco/growth/managed_auto_ingress'
  require_relative '../../lib/toybaco/growth/reply_delivery'
  require_relative '../../lib/toybaco/growth/posting_principal'
  require_relative '../../lib/toybaco/ai_readiness'

  boundaries = Toybaco::Growth::ManagedAutoBoundaries
  ingress = Toybaco::Growth::ManagedAutoIngress
  Message.include(ingress::MessageWrites) unless Message < ingress::MessageWrites
  AgentBot.include(boundaries::BotWrites) unless AgentBot < boundaries::BotWrites
  AgentBotInbox.include(boundaries::AssignmentWrites) unless AgentBotInbox < boundaries::AssignmentWrites
  [[Toybaco::AiReadiness.singleton_class, boundaries::Readiness],
   [Toybaco::AiReplyController, boundaries::LegacyMode],
   [Toybaco::Growth::PostingPrincipal.singleton_class, boundaries::Principals],
   [Toybaco::AiReplyMode.singleton_class, boundaries::Mode],
   [AgentBotListener, Toybaco::Growth::ManagedAutoIngress::Listener],
   [Toybaco::Growth::InboxRetention, boundaries::Hold], [Toybaco::Growth::AiLedger, boundaries::Reservations],
   [Toybaco::Growth::ReplyDelivery, boundaries::Delivery], [Api::BaseController, boundaries::ApiToken],
   [Toybaco::AiUsageController, boundaries::UsageApi]].each do |base, adapter|
    base.prepend(adapter) unless base < adapter
  end
end
